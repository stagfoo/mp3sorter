/// Looking covers up online, without going online.
///
/// Every test here runs against an injected fetcher, which is the whole
/// reason the network is one function. The rules being pinned down:
///
///  * the rate limit is honoured, because it is the condition on which
///    MusicBrainz lets anyone use it at all;
///  * a match this is not sure about writes nothing;
///  * a failure that applies to every album stops the run instead of
///    repeating itself a hundred times.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/artwork.dart';
import 'package:mp3sorter/cover_art.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/track.dart';

Uint8List jpeg() =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(64, 0x11)]);

Uint8List body(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, Object?> rg(
  String id,
  String title,
  String artist, {
  int score = 100,
}) =>
    {
      'id': id,
      'title': title,
      'score': score,
      'artist-credit': [
        {'name': artist}
      ],
    };

/// A fetcher that answers the search with [groups] and the image with
/// [image], and records what it was asked for.
({Fetcher fetch, List<Uri> calls}) fakeNetwork({
  List<Map<String, Object?>> groups = const [],
  List<Map<String, Object?>>? titleOnlyGroups,
  Uint8List? image,
  int searchStatus = 200,
  int imageStatus = 200,
}) {
  final calls = <Uri>[];
  Future<FetchResult> fetch(Uri url) async {
    calls.add(url);
    if (url.host.contains('musicbrainz')) {
      // The title-only retry is the one with no artist term in it.
      final isTitleOnly =
          !(url.queryParameters['query'] ?? '').contains('artist:');
      return FetchResult(
        searchStatus,
        body({
          'release-groups': isTitleOnly ? (titleOnlyGroups ?? const []) : groups
        }),
      );
    }
    return FetchResult(imageStatus, image ?? Uint8List(0));
  }

  return (fetch: fetch, calls: calls);
}

void main() {
  group('the search URL', () {
    test('it asks for release groups, as JSON, a few at a time', () {
      final url = musicBrainzSearch('Wolfmother', 'Cosmic Egg');
      expect(url.host, 'musicbrainz.org');
      expect(url.path, '/ws/2/release-group/');
      expect(url.queryParameters['fmt'], 'json');
      expect(url.queryParameters['query'],
          'artist:"Wolfmother" AND releasegroup:"Cosmic Egg"');
    });

    test('Lucene punctuation in a title does not become a syntax error', () {
      // Real titles contain all of this. A query that fails to parse
      // returns an error, not a worse match, so it has to be handled.
      final url = musicBrainzSearch('AC/DC', 'Who Made Who (Remastered)');
      final query = url.queryParameters['query']!;
      expect(query, isNot(contains('/')));
      expect(query, isNot(contains('(')));
      expect(query, contains('AC DC'));
    });

    test('a release group is what the archive indexes a cover under', () {
      // Six pressings of one record are six releases and one group.
      expect(coverArtUrl('b9b3ba85').path,
          '/release-group/b9b3ba85/front-$kCoverSize');
    });
  });

  group('reading a search response', () {
    test('it reads id, title, artist and score', () {
      final parsed = parseReleaseGroups(utf8.decode(body({
        'release-groups': [rg('abc', 'Cosmic Egg', 'Wolfmother', score: 97)]
      })));
      expect(parsed.single.id, 'abc');
      expect(parsed.single.title, 'Cosmic Egg');
      expect(parsed.single.artist, 'Wolfmother');
      expect(parsed.single.score, 97);
    });

    test('a collaboration credits every artist', () {
      final parsed = parseReleaseGroups(jsonEncode({
        'release-groups': [
          {
            'id': 'x',
            'title': 'Split',
            'artist-credit': [
              {'name': 'One'},
              {'name': 'Two'},
            ],
          }
        ]
      }));
      expect(parsed.single.artist, 'One Two');
    });

    test('a credit nested under artist is still read', () {
      final parsed = parseReleaseGroups(jsonEncode({
        'release-groups': [
          {
            'id': 'x',
            'title': 'T',
            'artist-credit': [
              {'artist': {'name': 'Deep'}}
            ],
          }
        ]
      }));
      expect(parsed.single.artist, 'Deep');
    });

    test('a malformed row costs that row, not the response', () {
      final parsed = parseReleaseGroups(jsonEncode({
        'release-groups': [
          {'no': 'id'},
          rg('good', 'T', 'A'),
        ]
      }));
      expect(parsed.map((g) => g.id), ['good']);
    });

    test('nonsense is an empty list, not an exception', () {
      // One odd response must not abort a run of a hundred albums.
      expect(parseReleaseGroups('<html>503</html>'), isEmpty);
      expect(parseReleaseGroups('[]'), isEmpty);
      expect(parseReleaseGroups(''), isEmpty);
    });
  });

  group('choosing a match', () {
    test('an exact title and artist matches', () {
      final best = bestMatch(
        [ReleaseGroupMatch(
            id: 'a', title: 'Cosmic Egg', artist: 'Wolfmother', score: 100)],
        'Wolfmother',
        'Cosmic Egg',
      );
      expect(best?.id, 'a');
    });

    test('capitalisation and punctuation do not defeat it', () {
      final best = bestMatch(
        [ReleaseGroupMatch(
            id: 'a', title: 'METAL RESISTANCE', artist: 'BABYMETAL', score: 90)],
        'Babymetal',
        'Metal Resistance',
      );
      expect(best?.id, 'a');
    });

    test('a high score for a different record is refused', () {
      // The failure this guards: MusicBrainz always returns something,
      // scored in the nineties, even for an album it has never heard of.
      // Writing that cover into forty files is worse than writing none.
      final best = bestMatch(
        [ReleaseGroupMatch(
            id: 'a', title: 'Greatest Hits', artist: 'Wolfmother', score: 98)],
        'Wolfmother',
        'Cosmic Egg',
      );
      expect(best, isNull);
    });

    test('the right album by the wrong artist is refused', () {
      final best = bestMatch(
        [ReleaseGroupMatch(
            id: 'a', title: 'Cosmic Egg', artist: 'Some Tribute Band',
            score: 95)],
        'Wolfmother',
        'Cosmic Egg',
      );
      expect(best, isNull);
    });

    test('a compilation crediting many artists still matches one of them', () {
      final best = bestMatch(
        [ReleaseGroupMatch(
            id: 'a',
            title: 'Now That What I Call Music',
            artist: 'Various Artists Wolfmother Muse',
            score: 80)],
        'Wolfmother',
        'Now That What I Call Music',
      );
      expect(best?.id, 'a');
    });

    test('their score only breaks ties between equally good titles', () {
      final best = bestMatch(
        [
          ReleaseGroupMatch(id: 'low', title: 'Cosmic Egg', artist: 'W', score: 40),
          ReleaseGroupMatch(id: 'high', title: 'Cosmic Egg', artist: 'W', score: 99),
        ],
        'W',
        'Cosmic Egg',
      );
      expect(best?.id, 'high');
    });

    test('nothing to choose from is nothing', () {
      expect(bestMatch(const [], 'A', 'B'), isNull);
    });
  });

  group('the rate limit', () {
    test('the first call waits for nothing', () {
      expect(Pacer().debt(), Duration.zero);
    });

    test('a second call immediately after owes nearly the full interval', () async {
      var now = DateTime(2026, 10, 15, 12, 0, 0);
      final slept = <Duration>[];
      final pacer = Pacer(
        interval: const Duration(milliseconds: 1100),
        clock: () => now,
        sleep: (d) async {
          slept.add(d);
          now = now.add(d);
        },
      );

      await pacer.wait();
      await pacer.wait();
      expect(slept, [const Duration(milliseconds: 1100)]);
    });

    test('a call after the interval has passed waits for nothing', () async {
      var now = DateTime(2026, 10, 15, 12, 0, 0);
      final slept = <Duration>[];
      final pacer = Pacer(
        interval: const Duration(milliseconds: 1100),
        clock: () => now,
        sleep: (d) async => slept.add(d),
      );

      await pacer.wait();
      now = now.add(const Duration(seconds: 5));
      await pacer.wait();
      expect(slept, isEmpty);
    });

    test('the interval leaves margin over one per second', () {
      // Aimed at exactly one per second, a client crosses the limit
      // whenever the network delivers two requests closer together than
      // they were sent.
      expect(kMusicBrainzInterval.inMilliseconds, greaterThan(1000));
    });

    test('the User-Agent identifies the app and a way to reach its author', () {
      // MusicBrainz asks for this, and an anonymous client that
      // misbehaves can only be dealt with by blocking it.
      expect(kUserAgent, contains('mp3sorter/'));
      expect(kUserAgent, contains('http'));
    });
  });

  group('one lookup end to end', () {
    test('a good match comes back with bytes and what it matched', () async {
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        image: jpeg(),
      );
      final result = await CoverArtLookup(
        fetch: net.fetch,
        pacer: Pacer(interval: Duration.zero),
      ).find('Wolfmother', 'Cosmic Egg');

      expect(result.isFound, isTrue);
      expect(result.cover!.mimeType, 'image/jpeg');
      expect(result.cover!.releaseGroupId, 'mbid-1');
      expect(result.cover!.matchedTitle, 'Cosmic Egg');
      expect(net.calls, hasLength(2), reason: 'a search, then the image');
    });

    test('a known album with no uploaded cover is a plain no', () async {
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        imageStatus: 404,
      );
      final result = await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('Wolfmother', 'Cosmic Egg');

      expect(result.failure, LookupFailure.noArt);
      expect(result.shouldStop, isFalse, reason: 'the next album may have one');
    });

    test('no match means the image is never asked for', () async {
      final net = fakeNetwork(groups: [rg('x', 'Something Else', 'Nobody')]);
      final result = await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('Wolfmother', 'Cosmic Egg');

      expect(result.failure, LookupFailure.noMatch);
      expect(net.calls, hasLength(2),
          reason: 'the search and the title-only retry, and no image');
      expect(net.calls.every((u) => u.host.contains('musicbrainz')), isTrue);
      expect(result.detail, contains('Something Else'),
          reason: 'saying what it nearly matched is what makes it checkable');
    });

    test('a rate limit says stop, not "no art"', () async {
      final net = fakeNetwork(searchStatus: 503);
      final result = await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('A', 'B');
      expect(result.failure, LookupFailure.rateLimited);
      expect(result.shouldStop, isTrue);
    });

    test('an error page served as the image is not embedded', () async {
      // The one that would otherwise put "<html>404</html>" into the
      // cover frame of forty files.
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        image: Uint8List.fromList(utf8.encode('<html>not found</html>')),
      );
      final result = await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('Wolfmother', 'Cosmic Egg');
      expect(result.failure, LookupFailure.notAnImage);
    });

    test('a dead network is reported as one, and stops the run', () async {
      Future<FetchResult> boom(Uri url) async =>
          throw const SocketExceptionLike();
      final result = await CoverArtLookup(
              fetch: boom, pacer: Pacer(interval: Duration.zero))
          .find('A', 'B');
      expect(result.failure, LookupFailure.networkError);
      expect(result.shouldStop, isTrue);
    });
  });

  group('the title-only fallback', () {
    test('a search on the title alone is shaped right', () {
      final url = musicBrainzTitleSearch('Cosmic Egg');
      expect(url.queryParameters['query'], 'releasegroup:"Cosmic Egg"');
      expect(url.queryParameters['query'], isNot(contains('artist:')));
    });

    test('exactly one near-exact hit is accepted', () {
      // The real case this exists for: MusicBrainz credits Final
      // Fantasy III Original Soundtrack to 植松伸夫, so searching under
      // "Nobuo Uematsu" returns nothing at all, while the title alone
      // returns one record with the title matching exactly.
      final only = onlyConfidentTitleMatch(
        [
          ReleaseGroupMatch(
              id: 'a',
              title: 'FINAL FANTASY III Original Soundtrack',
              artist: '植松伸夫',
              score: 100)
        ],
        'Final Fantasy III Original Soundtrack',
      );
      expect(only?.id, 'a');
    });

    test('more than one hit is refused without comparing anything', () {
      // Which is how "Greatest Hits" is kept safe: a title shared by a
      // thousand records returns a page of them and disqualifies itself
      // by being common.
      final refused = onlyConfidentTitleMatch(
        [
          ReleaseGroupMatch(
              id: 'a', title: 'Greatest Hits', artist: 'One', score: 100),
          ReleaseGroupMatch(
              id: 'b', title: 'Greatest Hits', artist: 'Two', score: 100),
        ],
        'Greatest Hits',
      );
      expect(refused, isNull);
    });

    test('one hit whose title is merely close is refused', () {
      // No artist is being checked here, so the title is all there is.
      final refused = onlyConfidentTitleMatch(
        [
          ReleaseGroupMatch(
              id: 'a', title: 'Cosmic Eggs Live', artist: 'W', score: 100)
        ],
        'Cosmic Egg',
      );
      expect(refused, isNull);
    });

    test('nothing at all is refused', () {
      expect(onlyConfidentTitleMatch(const [], 'Anything'), isNull);
    });

    test('the lookup falls back and finds the cover', () async {
      final net = fakeNetwork(
        groups: const [],
        titleOnlyGroups: [
          rg('mbid-jp', 'FINAL FANTASY III Original Soundtrack', '植松伸夫'),
        ],
        image: jpeg(),
      );
      final result = await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('Nobuo Uematsu', 'Final Fantasy III Original Soundtrack');

      expect(result.isFound, isTrue);
      expect(result.cover!.releaseGroupId, 'mbid-jp');
      expect(net.calls, hasLength(3),
          reason: 'the search, the title-only retry, then the image');
    });

    test('a good first match means no second search', () async {
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        image: jpeg(),
      );
      await CoverArtLookup(
              fetch: net.fetch, pacer: Pacer(interval: Duration.zero))
          .find('Wolfmother', 'Cosmic Egg');
      expect(net.calls, hasLength(2));
    });

    test('a rate limit on the retry still says stop', () async {
      final net = fakeNetwork(groups: const [], searchStatus: 200);
      var n = 0;
      Future<FetchResult> flaky(Uri url) async {
        n++;
        if (n == 1) return net.fetch(url);
        return FetchResult(503, Uint8List(0));
      }

      final result = await CoverArtLookup(
              fetch: flaky, pacer: Pacer(interval: Duration.zero))
          .find('A', 'B');
      expect(result.failure, LookupFailure.rateLimited);
      expect(result.shouldStop, isTrue);
    });

    test('the fallback is still paced', () async {
      // Three requests per album, all of them to the same people.
      var now = DateTime(2026, 10, 15);
      final slept = <Duration>[];
      final net = fakeNetwork(
        groups: const [],
        titleOnlyGroups: [rg('m', 'Exactly This', 'Whoever')],
        image: jpeg(),
      );
      await CoverArtLookup(
        fetch: net.fetch,
        pacer: Pacer(
          interval: const Duration(milliseconds: 1100),
          clock: () => now,
          sleep: (d) async {
            slept.add(d);
            now = now.add(d);
          },
        ),
      ).find('Whoever', 'Exactly This');

      expect(slept, hasLength(2), reason: 'two gaps between three requests');
    });
  });

  group('the online pass', () {
    late Directory tmp;
    final slept = <Duration>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mp3sorter_art');
      // Cleared per test: it is captured by the harvest's injected
      // sleep, which is built once per group.
      slept.clear();
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    List<AlbumArt> needing(List<(String, String)> pairs) => planArtwork(
          [
            for (final (artist, album) in pairs)
              Track(
                path: '/m/$artist/$album/01.mp3',
                sizeBytes: 1000,
                artist: artist,
                album: album,
                title: 'a',
              ),
          ],
          embeddedArt: const {},
          folderImages: const {},
        );

    CoverArtHarvest harvestWith(Fetcher fetch) => CoverArtHarvest(
          lookup: CoverArtLookup(
              fetch: fetch, pacer: Pacer(interval: Duration.zero)),
          cacheDir: Directory('${tmp.path}/cache'),
          sleep: (d) async => slept.add(d),
        );

    test('a found cover is cached to a file and the album points at it',
        () async {
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        image: jpeg(),
      );
      final result =
          await harvestWith(net.fetch).run(needing([('Wolfmother', 'Cosmic Egg')]));

      expect(result.filled, hasLength(1));
      final album = result.filled.single;
      expect(album.source, ArtSource.downloaded);
      expect(album.sourceMimeType, 'image/jpeg');
      expect(File(album.sourcePath!).existsSync(), isTrue);
      expect(album.sourcePath, endsWith('mbid-1.jpg'));
      expect(result.stoppedEarly, isFalse);
    });

    test('a downloaded cover becomes ordinary, reviewable, undoable actions',
        () async {
      // Nothing about the online path bypasses the plan — the same
      // review and the same journal as every other change.
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'Cosmic Egg', 'Wolfmother')],
        image: jpeg(),
      );
      final result =
          await harvestWith(net.fetch).run(needing([('Wolfmother', 'Cosmic Egg')]));
      final actions = artActions(result.filled);

      expect(actions.map((a) => a.kind),
          [ActionKind.writeCover, ActionKind.embedArt]);
      expect(actions.first.reason, contains('Cover Art Archive'));
    });

    test('albums with no cover available are named, not just counted',
        () async {
      final net = fakeNetwork(groups: const []);
      final result = await harvestWith(net.fetch)
          .run(needing([('Nobody', 'Nothing'), ('Also', 'Missing')]));

      expect(result.filled, isEmpty);
      expect(result.notes, hasLength(2));
      expect(result.notes.join('\n'), contains('Nobody — Nothing'));
      expect(result.notes.join('\n'), contains('Also — Missing'));
      expect(result.stoppedEarly, isFalse,
          reason: 'each album genuinely has none; the run finished');
    });

    test('a rate limit backs off and retries the same album', () async {
      // Observed live: MusicBrainz returns 503 under load even for a
      // client pacing itself correctly. Abandoning fifty-seven albums
      // over one of those is both annoying and more traffic than
      // backing off.
      var calls = 0;
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'One', 'A')],
        image: jpeg(),
      );
      Future<FetchResult> flaky(Uri url) async {
        calls++;
        if (calls <= 2) return FetchResult(503, Uint8List(0));
        return net.fetch(url);
      }

      final result = await harvestWith(flaky).run(needing([('A', 'One')]));

      expect(result.filled, hasLength(1), reason: 'it got there in the end');
      expect(result.stoppedEarly, isFalse);
      expect(slept, [const Duration(seconds: 5), const Duration(seconds: 10)],
          reason: 'the wait doubles, rather than retrying at the same rate');
    });

    test('a rate limit that outlasts every backoff stops the run', () async {
      Future<FetchResult> limited(Uri url) async =>
          FetchResult(503, Uint8List(0));

      final result = await harvestWith(limited).run(needing([
        ('A', 'One'),
        ('B', 'Two'),
        ('C', 'Three'),
      ]));

      expect(slept, hasLength(kRateLimitRetries));
      expect(result.stoppedEarly, isTrue);
      expect(result.notes, hasLength(1),
          reason: 'the other two albums were not attempted');
    });

    test('backing off is not a way to keep hammering', () async {
      // Each wait must be longer than the last, and all of them much
      // longer than the request interval.
      Future<FetchResult> limited(Uri url) async =>
          FetchResult(503, Uint8List(0));
      await harvestWith(limited).run(needing([('A', 'One')]));
      for (var i = 1; i < slept.length; i++) {
        expect(slept[i], greaterThan(slept[i - 1]));
      }
      expect(slept.first, greaterThan(kMusicBrainzInterval * 2));
    });

    test('it can be cancelled part-way and says so', () async {
      final net = fakeNetwork(
        groups: [rg('mbid-1', 'One', 'A')],
        image: jpeg(),
      );
      var seen = 0;
      final result = await harvestWith(net.fetch).run(
        needing([('A', 'One'), ('B', 'Two'), ('C', 'Three')]),
        onProgress: (done, total, what) => seen = done,
        isCancelled: () => seen >= 1,
      );
      expect(result.stoppedEarly, isTrue);
      expect(result.filled, hasLength(1));
    });

    test('progress names the album being looked up', () async {
      // Because an unexplained two-minute pause reads as a hang.
      final net = fakeNetwork(groups: const []);
      final labels = <String>[];
      await harvestWith(net.fetch).run(
        needing([('Wolfmother', 'Cosmic Egg')]),
        onProgress: (done, total, what) => labels.add(what),
      );
      expect(labels.single, 'Wolfmother — Cosmic Egg');
    });
  });
}

/// Stands in for whatever `dart:io` throws when there is no network.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
  @override
  String toString() => 'no route to host';
}
