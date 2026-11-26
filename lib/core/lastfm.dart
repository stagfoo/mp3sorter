/// Genre suggestions from Last.fm's community tags.
///
/// Optional: Last.fm needs an API key (free, from last.fm/api), so this only
/// runs once one has been entered in settings. MusicBrainz's own genre tags
/// are sparse; Last.fm's are what most people would call the genre.
library;

import 'dart:convert';

import 'net.dart';
import 'tags.dart';

Uri lastFmTopTags({
  required String apiKey,
  required String artist,
  required String title,
}) =>
    Uri.https('ws.audioscrobbler.com', '/2.0/', {
      'method': 'track.gettoptags',
      'artist': artist,
      'track': title,
      'autocorrect': '1',
      'api_key': apiKey,
      'format': 'json',
    });

/// Tags that are popular on Last.fm and are not genres.
const Set<String> _notGenres = {
  'seen live',
  'favorites',
  'favourites',
  'favorite',
  'love',
  'loved',
  'awesome',
  'beautiful',
  'albums i own',
  'my favorite',
  'under 2000 listeners',
};

/// The top few genre-like tags, best first.
List<String> parseTopTags(String body, {int limit = 3}) {
  try {
    final root = jsonDecode(body);
    final tags = (root is Map && root['toptags'] is Map)
        ? (root['toptags'] as Map)['tag']
        : null;
    if (tags is! List) return const [];
    final out = <String>[];
    for (final t in tags) {
      if (t is! Map) continue;
      final name = (t['name'] as String?)?.trim();
      if (name == null || name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (_notGenres.contains(lower)) continue;
      // Decades and years are tags, not genres.
      if (RegExp(r"^\d{2,4}'?s?$").hasMatch(lower)) continue;
      out.add(name[0].toUpperCase() + name.substring(1));
      if (out.length >= limit) break;
    }
    return out;
  } on FormatException {
    return const [];
  }
}

class LastFmLookup {
  LastFmLookup(this.client, this.apiKey);
  final JsonClient client;
  final String apiKey;

  Future<List<Candidate>> genres({
    required String artist,
    required String title,
  }) async {
    if (apiKey.trim().isEmpty) return const [];
    final (_, body) = await client.get(
        lastFmTopTags(apiKey: apiKey.trim(), artist: artist, title: title));
    if (body == null) return const [];
    return [
      for (final g in parseTopTags(body))
        Candidate(
          label: g,
          source: CandidateSource.lastFm,
          tags: TagSet(genre: g),
          score: 5,
        ),
    ];
  }
}
