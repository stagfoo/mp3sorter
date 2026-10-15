/// Fetching cover art from MusicBrainz and the Cover Art Archive.
///
/// ## Why not Spotify
///
/// Spotify was the obvious first thought and it cannot be used for this.
/// Their Developer Terms say, of Spotify Content — which explicitly
/// includes cover art:
///
///   * *"Do not store Spotify Content indefinitely"*
///   * *"Local caching. Do not locally cache any Spotify Content"*
///
/// Embedding a cover into an MP3 on a card is precisely indefinite local
/// storage of Spotify Content. The feature would be built on a licence
/// term it breaks on the first file, so it is not built on Spotify.
///
/// MusicBrainz has no such problem: its data is CC0, the Cover Art
/// Archive serves images contributed for exactly this, and neither needs
/// an API key. The obligations are different in kind — be polite, which
/// is what [Pacer] and the User-Agent below are for.
///
/// ## Politeness, as a hard requirement
///
/// MusicBrainz rate-limits to roughly one request per second per client
/// and asks for a User-Agent identifying the application. Both are
/// honoured here, not as best effort: 106 albums at one per second is
/// under two minutes, and there is no version of this feature worth
/// getting the app's address blocked for.
///
/// The parsing and selection logic is pure and separately tested; the
/// network is behind a single injectable function so none of the tests
/// reach it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'artwork.dart';
import 'levenshtein.dart';
import 'version.dart';

/// Identifies this app to MusicBrainz, as their guidelines require.
///
/// A real contact is part of the ask — an anonymous client that
/// misbehaves can only be dealt with by blocking it.
const String kUserAgent =
    'mp3sorter/$kAppVersion ( https://github.com/alexanderddking/mp3sorter )';

/// One request per second, with a little margin.
///
/// 1.1s rather than 1.0s on purpose. The limit is enforced on arrival
/// time at their end, and a client that aims exactly at the limit
/// crosses it whenever the network delivers two requests closer together
/// than they were sent.
const Duration kMusicBrainzInterval = Duration(milliseconds: 1100);

/// How big a cover to ask for. 500px is the Cover Art Archive's standard
/// thumbnail: large enough to look right on a phone and in a car stereo,
/// small enough that embedding it in every track does not add tens of
/// megabytes to the collection.
const int kCoverSize = 500;

/// Refuses to let calls happen faster than an interval.
///
/// Separate and pure-ish so the rate limit can be tested by advancing a
/// clock rather than by waiting a real second per assertion.
class Pacer {
  Pacer({
    this.interval = kMusicBrainzInterval,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  })  : _now = clock ?? DateTime.now,
        _sleep = sleep ?? Future.delayed;

  final Duration interval;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  DateTime? _last;

  /// How long a call right now would have to wait.
  Duration debt() {
    final last = _last;
    if (last == null) return Duration.zero;
    final since = _now().difference(last);
    return since >= interval ? Duration.zero : interval - since;
  }

  Future<void> wait() async {
    final owed = debt();
    if (owed > Duration.zero) await _sleep(owed);
    _last = _now();
  }
}

/// What one HTTP GET came back with.
class FetchResult {
  const FetchResult(this.status, this.bytes, {this.contentType});

  final int status;
  final Uint8List bytes;
  final String? contentType;

  bool get ok => status >= 200 && status < 300;
  bool get notFound => status == 404;

  /// Worth trying again later rather than treated as "no art exists".
  /// 503 is what MusicBrainz returns when it is rate-limiting.
  bool get transient => status == 429 || status == 503 || status >= 500;
}

/// The one piece of network in this file.
typedef Fetcher = Future<FetchResult> Function(Uri url);

/// A cover that was found.
class FoundCover {
  const FoundCover({
    required this.bytes,
    required this.mimeType,
    required this.releaseGroupId,
    required this.matchedTitle,
  });

  final Uint8List bytes;
  final String mimeType;
  final String releaseGroupId;

  /// What MusicBrainz called the record. Shown in the review list so a
  /// wrong match is visible before it is written to forty files.
  final String matchedTitle;
}

/// Why a lookup came back with nothing. Distinguished because they call
/// for different responses: "no art exists" is final, "rate limited" is
/// a reason to slow down and try again.
enum LookupFailure { noMatch, noArt, rateLimited, networkError, notAnImage }

class LookupResult {
  const LookupResult.found(this.cover) : failure = null, detail = '';
  const LookupResult.failed(this.failure, this.detail) : cover = null;

  final FoundCover? cover;
  final LookupFailure? failure;
  final String detail;

  bool get isFound => cover != null;

  /// Whether carrying on through the rest of the queue is sensible.
  /// A rate limit or a dead network applies to every remaining album,
  /// so hammering through 106 of them achieves nothing.
  bool get shouldStop =>
      failure == LookupFailure.rateLimited ||
      failure == LookupFailure.networkError;
}

/// Builds the MusicBrainz search URL.
///
/// A release *group* rather than a release: a record pressed in six
/// countries is six releases and one group, and the group is what the
/// Cover Art Archive indexes a single front cover under. Searching
/// releases means picking between six near-identical rows for no gain.
Uri musicBrainzSearch(String artist, String album) {
  // Quoted so a multi-word title is one term. Lucene's special
  // characters are stripped rather than escaped — an album title is not
  // a query language, and a stray bracket turning into a syntax error is
  // a worse outcome than a slightly looser search.
  final query = 'artist:"${_forLucene(artist)}" '
      'AND releasegroup:"${_forLucene(album)}"';
  return Uri.https('musicbrainz.org', '/ws/2/release-group/', {
    'query': query,
    'fmt': 'json',
    'limit': '5',
  });
}

/// Searches on the album title alone.
///
/// The fallback for a real and common case: MusicBrainz credits the
/// album to a name the tags do not use. *Final Fantasy III Original
/// Soundtrack* is in there, credited to 植松伸夫 — so
/// `artist:"Nobuo Uematsu" AND releasegroup:"..."` returns nothing at
/// all, while the title alone returns exactly one record, scored 100,
/// with the title matching character for character.
///
/// Safe only because of how narrowly its result is accepted — see
/// [onlyConfidentTitleMatch].
Uri musicBrainzTitleSearch(String album) => Uri.https(
      'musicbrainz.org',
      '/ws/2/release-group/',
      {
        'query': 'releasegroup:"${_forLucene(album)}"',
        'fmt': 'json',
        // More than one hit disqualifies the fallback, so there is no
        // reason to ask for more than enough to know that.
        'limit': '3',
      },
    );

String _forLucene(String raw) =>
    raw.replaceAll(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// Where the Cover Art Archive keeps a release group's front cover.
Uri coverArtUrl(String releaseGroupId) => Uri.https(
      'coverartarchive.org',
      '/release-group/$releaseGroupId/front-$kCoverSize',
    );

/// One candidate from a MusicBrainz search.
class ReleaseGroupMatch {
  const ReleaseGroupMatch({
    required this.id,
    required this.title,
    required this.artist,
    required this.score,
  });

  final String id;
  final String title;
  final String artist;

  /// MusicBrainz's own 0–100 confidence.
  final int score;
}

/// Reads the candidates out of a search response.
///
/// Tolerant by design: a missing field costs that candidate, and a
/// response shaped differently from expectation yields an empty list
/// rather than an exception. The alternative is one odd record aborting
/// a run of a hundred albums.
List<ReleaseGroupMatch> parseReleaseGroups(String body) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  if (root is! Map) return const [];
  final groups = root['release-groups'];
  if (groups is! List) return const [];

  final out = <ReleaseGroupMatch>[];
  for (final raw in groups) {
    if (raw is! Map) continue;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || id.isEmpty || title is! String) continue;

    // The artist comes as a credit list, so a collaboration is several
    // names joined by whatever the credit says.
    final credits = raw['artist-credit'];
    final names = <String>[];
    if (credits is List) {
      for (final c in credits) {
        if (c is! Map) continue;
        final name = c['name'] ?? (c['artist'] is Map ? c['artist']['name'] : null);
        if (name is String && name.isNotEmpty) names.add(name);
      }
    }

    out.add(ReleaseGroupMatch(
      id: id,
      title: title,
      artist: names.join(' '),
      score: (raw['score'] as num?)?.toInt() ?? 0,
    ));
  }
  return out;
}

/// How confident a match has to be before its art gets written into
/// somebody's files.
///
/// Deliberately high. A wrong cover embedded in a whole album is worse
/// than no cover: it is wrong on every device, in every player, and the
/// only clue that it happened is that the picture does not match the
/// music. Being unsure and doing nothing is the better failure.
const double kMatchThreshold = 0.80;

/// Picks the candidate that is actually the record being looked for, or
/// nothing.
///
/// MusicBrainz's own score is not enough on its own: a search for an
/// album it has never heard of still returns five rows, the best of them
/// scored in the nineties, for a completely different record. So the
/// titles and artists are compared directly, with the same normalisation
/// the rest of the app uses for deciding two names are one name.
ReleaseGroupMatch? bestMatch(
  List<ReleaseGroupMatch> candidates,
  String artist,
  String album,
) {
  ReleaseGroupMatch? best;
  var bestScore = 0.0;

  for (final c in candidates) {
    final titleScore = nameSimilarity(c.title, album);
    if (titleScore < kMatchThreshold) continue;

    // The artist is checked loosely. "Babymetal" against "BABYMETAL"
    // normalises to the same thing, but a compilation credits twelve
    // artists and containment is the honest test there.
    final wanted = normaliseForMatching(artist);
    final credited = normaliseForMatching(c.artist);
    final artistOk = wanted.isEmpty ||
        credited.contains(wanted) ||
        wanted.contains(credited) ||
        nameSimilarity(c.artist, artist) >= kMatchThreshold;
    if (!artistOk) continue;

    // Their score breaks ties between two candidates this is equally
    // sure about; it never promotes one this is unsure about.
    final combined = titleScore + c.score / 10000;
    if (combined > bestScore) {
      bestScore = combined;
      best = c;
    }
  }

  return best;
}

/// How close a title-only match has to be. Nearly exact.
///
/// Higher than [kMatchThreshold] because the artist is not being
/// checked at all, and the artist is what normally stops a wrong match.
const double kTitleOnlyThreshold = 0.95;

/// Accepts a title-only search result, or refuses it.
///
/// Two conditions, and the first is the one that makes this safe: the
/// search must have returned **exactly one** release group. A
/// distinctive title — *Final Fantasy III Original Soundtrack* — returns
/// one. A title shared by a thousand records — *Greatest Hits*, *Live*,
/// *Demos* — returns a page of them, and is refused without the titles
/// ever being compared. Which is the whole point: the dangerous case
/// disqualifies itself by being common.
///
/// Then the one candidate's title has to match nearly exactly, because
/// nothing else is checking anything.
ReleaseGroupMatch? onlyConfidentTitleMatch(
  List<ReleaseGroupMatch> candidates,
  String album,
) {
  if (candidates.length != 1) return null;
  final only = candidates.single;
  if (nameSimilarity(only.title, album) < kTitleOnlyThreshold) return null;
  return only;
}

/// Reads the format out of the bytes rather than trusting the header.
///
/// Worth doing because the bytes get embedded with a declared mimetype,
/// and a JPEG announced as a PNG shows up as a broken image in players
/// that believe the declaration.
String? sniffImageType(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  // WEBP: "RIFF" .... "WEBP". Accepted for the folder image, where a
  // player reads the file itself, but see kEmbeddableTypes.
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// What is safe to put inside an ID3 tag.
///
/// WEBP is left out on purpose. ID3v2 will carry any mimetype, but a car
/// stereo from 2014 will not decode it, and a cover that renders as
/// nothing is indistinguishable from the missing cover this feature
/// exists to fix.
const Set<String> kEmbeddableTypes = {'image/jpeg', 'image/png'};

/// Looks up one album's cover.
class CoverArtLookup {
  CoverArtLookup({required this.fetch, Pacer? pacer})
      : _pacer = pacer ?? Pacer();

  /// Injected, so none of the tests for any of the above reach a network.
  final Fetcher fetch;
  final Pacer _pacer;

  /// Two requests per album: the search, then the image. Both paced,
  /// because both go to the same people.
  Future<LookupResult> find(String artist, String album) async {
    final FetchResult search;
    try {
      await _pacer.wait();
      search = await fetch(musicBrainzSearch(artist, album));
    } catch (e) {
      return LookupResult.failed(LookupFailure.networkError, '$e');
    }

    if (search.transient) {
      return LookupResult.failed(
          LookupFailure.rateLimited, 'MusicBrainz said ${search.status}');
    }
    if (!search.ok) {
      return LookupResult.failed(
          LookupFailure.noMatch, 'search returned ${search.status}');
    }

    final candidates = parseReleaseGroups(
        utf8.decode(search.bytes, allowMalformed: true));
    var match = bestMatch(candidates, artist, album);

    // Nothing under that artist. Try the title on its own, in case the
    // record is credited to a name the tags do not use.
    if (match == null) {
      final FetchResult retry;
      try {
        await _pacer.wait();
        retry = await fetch(musicBrainzTitleSearch(album));
      } catch (e) {
        return LookupResult.failed(LookupFailure.networkError, '$e');
      }
      if (retry.transient) {
        return LookupResult.failed(
            LookupFailure.rateLimited, 'MusicBrainz said ${retry.status}');
      }
      if (retry.ok) {
        match = onlyConfidentTitleMatch(
          parseReleaseGroups(utf8.decode(retry.bytes, allowMalformed: true)),
          album,
        );
      }
    }

    if (match == null) {
      return LookupResult.failed(
        LookupFailure.noMatch,
        candidates.isEmpty
            ? 'nothing found'
            : 'closest was "${candidates.first.title}", not close enough',
      );
    }

    final FetchResult image;
    try {
      await _pacer.wait();
      image = await fetch(coverArtUrl(match.id));
    } catch (e) {
      return LookupResult.failed(LookupFailure.networkError, '$e');
    }

    if (image.notFound) {
      // The commonest outcome for obscure records: MusicBrainz knows the
      // album, nobody has uploaded a cover for it.
      return LookupResult.failed(
          LookupFailure.noArt, 'no cover uploaded for "${match.title}"');
    }
    if (image.transient) {
      return LookupResult.failed(
          LookupFailure.rateLimited, 'the archive said ${image.status}');
    }
    if (!image.ok || image.bytes.isEmpty) {
      return LookupResult.failed(
          LookupFailure.noArt, 'the archive returned ${image.status}');
    }

    final type = sniffImageType(image.bytes);
    if (type == null || !kEmbeddableTypes.contains(type)) {
      return LookupResult.failed(LookupFailure.notAnImage,
          'what came back is not a cover this can embed');
    }

    return LookupResult.found(FoundCover(
      bytes: image.bytes,
      mimeType: type,
      releaseGroupId: match.id,
      matchedTitle: match.title,
    ));
  }
}

/// The real network, kept to one function.
///
/// `dart:io` rather than a package: this needs exactly one GET with a
/// User-Agent and redirects followed, and that is three lines here
/// against another dependency to keep pinned.
Fetcher httpFetcher({Duration timeout = const Duration(seconds: 20)}) {
  final client = HttpClient()
    ..userAgent = kUserAgent
    ..connectionTimeout = timeout;

  return (Uri url) async {
    // The Cover Art Archive answers with a 307 to archive.org, so
    // redirects must be followed — the default, stated here because
    // turning it off would break every image fetch.
    final request = await client.getUrl(url);
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json, image/*');

    final response = await request.close().timeout(timeout);
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
    }
    return FetchResult(
      response.statusCode,
      Uint8List.fromList(chunks),
      contentType: response.headers.contentType?.mimeType,
    );
  };
}

/// How many times in a row a rate limit is tolerated before giving up.
///
/// Not zero, which is what the first version did, and it was wrong.
/// MusicBrainz returns 503 under load even for a client pacing itself
/// correctly — observed twice in a run of six albums paced at 1.1s. One
/// of those abandoning the other fifty-seven albums means pressing the
/// button again and again, which is both annoying and *more* traffic
/// than backing off would have been.
const int kRateLimitRetries = 4;

/// How long to wait after a rate limit, before the first retry.
///
/// Doubled each time. Deliberately much longer than the request
/// interval: a 503 means "you are asking too fast", and the response to
/// that is to slow down substantially, not to try again in a second.
const Duration kBackoff = Duration(seconds: 5);

/// What happened when the online pass ran.
class HarvestResult {
  const HarvestResult({
    required this.filled,
    required this.notes,
    required this.stoppedEarly,
  });

  /// Albums that now have a source, ready to be turned into actions.
  final List<AlbumArt> filled;

  /// One line per album that did not get a cover, saying why. Reported
  /// rather than counted: "47 not found" is not something anyone can act
  /// on, and "no cover uploaded for X" is.
  final List<String> notes;

  /// True when the run gave up rather than finishing — a rate limit, or
  /// the network going away. The distinction matters: a finished run
  /// means those albums genuinely have no art available, and a stopped
  /// one means try again later.
  final bool stoppedEarly;
}

/// Looks up every album that needs it, politely, one at a time.
///
/// Sequential on purpose. Two requests in flight is two requests per
/// second however carefully each one is paced, and the whole reason this
/// is allowed to touch MusicBrainz at all is that it does not do that.
class CoverArtHarvest {
  CoverArtHarvest({
    required this.lookup,
    required this.cacheDir,
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? Future.delayed;

  final CoverArtLookup lookup;
  final Future<void> Function(Duration) _sleep;

  /// Where downloaded covers land before being written into files.
  ///
  /// A file rather than memory, so an art action stays a pair of paths
  /// and a hundred downloaded covers do not sit in RAM waiting for a
  /// review screen to be confirmed.
  final Directory cacheDir;

  Future<HarvestResult> run(
    List<AlbumArt> albums, {
    void Function(int done, int total, String what)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final filled = <AlbumArt>[];
    final notes = <String>[];
    var stopped = false;

    await cacheDir.create(recursive: true);

    for (var i = 0; i < albums.length; i++) {
      if (isCancelled?.call() ?? false) {
        stopped = true;
        break;
      }
      final album = albums[i];
      onProgress?.call(
          i + 1, albums.length, '${album.artist} — ${album.album}');

      // Retried on a rate limit, with the wait doubling each time, and
      // the album itself retried rather than skipped — a 503 says
      // nothing about whether this record has a cover.
      var result = await lookup.find(album.artist, album.album);
      var backoff = kBackoff;
      var retries = 0;
      while (result.failure == LookupFailure.rateLimited &&
          retries < kRateLimitRetries) {
        if (isCancelled?.call() ?? false) break;
        retries++;
        onProgress?.call(i + 1, albums.length,
            'rate limited — waiting ${backoff.inSeconds}s');
        await _sleep(backoff);
        backoff *= 2;
        result = await lookup.find(album.artist, album.album);
      }

      if (result.isFound) {
        final cover = result.cover!;
        final extension = cover.mimeType == 'image/png' ? 'png' : 'jpg';
        // Named after the release group, so an interrupted session
        // re-run reuses what was already downloaded rather than asking
        // MusicBrainz for it a second time.
        final file =
            File('${cacheDir.path}/${cover.releaseGroupId}.$extension');
        await file.writeAsBytes(cover.bytes, flush: true);
        filled.add(album.withSource(
            ArtSource.downloaded, file.path, cover.mimeType));
        continue;
      }

      notes.add('${album.artist} — ${album.album}: ${result.detail}');
      if (result.shouldStop) {
        // Either a dead network, or a rate limit that outlasted every
        // backoff. Both apply to every remaining album, so carrying on
        // would be a hundred more failures — and in the rate-limit case,
        // the thing most likely to get the app blocked.
        stopped = true;
        break;
      }
    }

    return HarvestResult(
      filled: filled,
      notes: notes,
      stoppedEarly: stopped,
    );
  }
}
