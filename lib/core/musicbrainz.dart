/// Turning a MusicBrainz recording search into candidate chips.
///
/// MusicBrainz is CC0 and needs no key, which is why it is the main source.
/// The URL building and response parsing are pure and tested against
/// captured responses; the network sits behind [JsonClient].
library;

import 'dart:convert';

import 'net.dart';
import 'tags.dart';

String _forLucene(String raw) => raw
    .replaceAll(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// The recording search for a title, narrowed by artist when one is known.
Uri recordingSearch({required String title, String? artist}) {
  final t = _forLucene(title);
  final a = artist == null ? '' : _forLucene(artist);
  final query =
      a.isEmpty ? 'recording:"$t"' : 'recording:"$t" AND artist:"$a"';
  return Uri.https('musicbrainz.org', '/ws/2/recording/', {
    'query': query,
    'fmt': 'json',
    'limit': '8',
  });
}

/// Front cover for a release, at the Cover Art Archive's 500px size: big
/// enough for a phone and a car stereo, small enough to embed in every track.
Uri releaseCoverUrl(String releaseId) =>
    Uri.https('coverartarchive.org', '/release/$releaseId/front-500');

Uri releaseGroupCoverUrl(String releaseGroupId) =>
    Uri.https('coverartarchive.org', '/release-group/$releaseGroupId/front-500');

String _credit(Object? credits) {
  if (credits is! List) return '';
  final b = StringBuffer();
  for (final c in credits) {
    if (c is! Map) continue;
    final name = c['name'] ??
        (c['artist'] is Map ? (c['artist'] as Map)['name'] : null);
    if (name is String) b.write(name);
    final join = c['joinphrase'];
    if (join is String) b.write(join);
  }
  return b.toString().trim();
}

int? _year(Object? date) {
  if (date is! String || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// The chip label for one release of a recording: what kind of release it
/// is, in the words the user would use.
String releaseLabel({
  required String recordingTitle,
  String? disambiguation,
  String? status,
  String? primaryType,
  List<String> secondaryTypes = const [],
}) {
  final text = '${recordingTitle.toLowerCase()} ${disambiguation?.toLowerCase() ?? ''}';
  if (secondaryTypes.contains('Live') || RegExp(r'\blive\b').hasMatch(text)) {
    return 'Live';
  }
  if (secondaryTypes.contains('Remix') ||
      RegExp(r'\b(remix|rmx|mix\))').hasMatch(text)) {
    return 'Remix';
  }
  if (RegExp(r'\bacoustic\b').hasMatch(text)) return 'Acoustic';
  if (RegExp(r'\b(demo)\b').hasMatch(text)) return 'Demo';
  if (secondaryTypes.contains('Soundtrack')) return 'Soundtrack';
  if (secondaryTypes.contains('Compilation')) return 'Compilation';
  if (status != null && status != 'Official') return status;
  return switch (primaryType) {
    'Single' => 'Single',
    'EP' => 'EP',
    _ => 'Official Release',
  };
}

/// Reads candidates out of a recording search response.
///
/// [fileSeconds] is the track's real length; a recording whose length is far
/// from it is almost certainly a different take, so it ranks low rather than
/// being dropped (a wrong length in MusicBrainz is not unheard of).
List<Candidate> parseRecordings(String body, {int? fileSeconds}) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  if (root is! Map) return const [];
  final recordings = root['recordings'];
  if (recordings is! List) return const [];

  final out = <Candidate>[];
  for (final rec in recordings) {
    if (rec is! Map) continue;
    final title = rec['title'];
    if (title is! String || title.isEmpty) continue;
    final artist = _credit(rec['artist-credit']);
    final mbScore = (rec['score'] as num?)?.toInt() ?? 0;
    final lengthMs = (rec['length'] as num?)?.toInt();
    final lengthS = lengthMs == null ? null : (lengthMs / 1000).round();
    final disambiguation = rec['disambiguation'] as String?;

    var lengthBonus = 0;
    if (fileSeconds != null && lengthS != null) {
      final off = (fileSeconds - lengthS).abs();
      lengthBonus = off <= 3 ? 40 : (off <= 10 ? 15 : -40);
    }

    String? genre;
    final tags = rec['tags'];
    if (tags is List && tags.isNotEmpty) {
      final sorted = tags.whereType<Map>().toList()
        ..sort((a, b) => ((b['count'] as num?) ?? 0)
            .compareTo((a['count'] as num?) ?? 0));
      final name = sorted.isEmpty ? null : sorted.first['name'];
      if (name is String && name.isNotEmpty) {
        genre = name[0].toUpperCase() + name.substring(1);
      }
    }

    final releases = rec['releases'];
    if (releases is! List || releases.isEmpty) {
      out.add(Candidate(
        label: releaseLabel(recordingTitle: title, disambiguation: disambiguation),
        source: CandidateSource.musicBrainz,
        tags: TagSet(artist: artist, title: title, genre: genre),
        lengthSeconds: lengthS,
        score: mbScore + lengthBonus,
      ));
      continue;
    }

    // A recording can be on dozens of releases. The first few are enough to
    // offer the album, the single and the live record; more is noise.
    var taken = 0;
    for (final rel in releases) {
      if (rel is! Map || taken >= 4) break;
      final relId = rel['id'] as String?;
      final relTitle = rel['title'] as String?;
      final status = rel['status'] as String?;
      final group = rel['release-group'];
      String? groupId, primary;
      var secondary = const <String>[];
      if (group is Map) {
        groupId = group['id'] as String?;
        primary = group['primary-type'] as String?;
        final s = group['secondary-types'];
        if (s is List) secondary = s.whereType<String>().toList();
      }
      int? trackNo;
      final media = rel['media'];
      if (media is List && media.isNotEmpty && media.first is Map) {
        final tracks = (media.first as Map)['track'];
        if (tracks is List && tracks.isNotEmpty && tracks.first is Map) {
          trackNo = int.tryParse('${(tracks.first as Map)['number']}');
        }
      }
      final relArtist = _credit(rel['artist-credit']);
      final albumArtist = relArtist.isNotEmpty
          ? relArtist
          : (secondary.contains('Compilation') ? 'Various Artists' : artist);

      var bonus = 0;
      if (status == 'Official') bonus += 10;
      if (primary == 'Album') bonus += 8;
      if (secondary.contains('Compilation')) bonus -= 8;

      out.add(Candidate(
        label: releaseLabel(
          recordingTitle: title,
          disambiguation: disambiguation,
          status: status,
          primaryType: primary,
          secondaryTypes: secondary,
        ),
        source: CandidateSource.musicBrainz,
        tags: TagSet(
          artist: artist,
          title: title,
          album: relTitle,
          albumArtist: albumArtist,
          year: _year(rel['date']) ?? _year(rec['first-release-date']),
          trackNumber: trackNo,
          genre: genre,
        ),
        releaseId: relId,
        releaseGroupId: groupId,
        lengthSeconds: lengthS,
        score: mbScore + lengthBonus + bonus - taken,
      ));
      taken++;
    }
  }
  out.sort((a, b) => b.score.compareTo(a.score));
  return dedupeCandidates(out);
}

/// What to search for, given what is already known about a track.
///
/// Existing tags win over the filename: a file with a real TIT2 frame was
/// tagged by someone, a filename was typed by anyone.
({String title, String? artist})? searchTerms(TagSet current, TagSet fromName) {
  final c = current.normalised();
  final n = fromName.normalised();
  final title = c.title ?? n.title;
  if (title == null) return null;
  return (title: title, artist: c.artist ?? n.artist);
}

/// The online lookup for one track.
class MusicBrainzLookup {
  MusicBrainzLookup(this.client);
  final JsonClient client;

  Future<(LookupStatus, List<Candidate>)> candidates({
    required String title,
    String? artist,
    int? fileSeconds,
  }) async {
    var (status, body) =
        await client.get(recordingSearch(title: title, artist: artist));
    var found = body == null
        ? const <Candidate>[]
        : parseRecordings(body, fileSeconds: fileSeconds);

    // Nothing under that artist: often the tags use a romanised or
    // misspelled name. The title alone, ranked by length, still finds it.
    if (found.isEmpty && artist != null && body != null) {
      final (s2, b2) = await client.get(recordingSearch(title: title));
      status = s2;
      if (b2 != null) found = parseRecordings(b2, fileSeconds: fileSeconds);
    }
    if (found.isEmpty && (status == LookupStatus.ok || status == LookupStatus.cached)) {
      status = LookupStatus.noMatch;
    }
    return (status, found.take(6).toList());
  }
}
