import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/lastfm.dart';
import 'package:mp3sorter/core/musicbrainz.dart';
import 'package:mp3sorter/core/net.dart';
import 'package:mp3sorter/core/tags.dart';

Map<String, Object?> recording({
  required String title,
  required int lengthMs,
  int score = 100,
  String? disambiguation,
  List<Map<String, Object?>> releases = const [],
  List<Map<String, Object?>> tags = const [],
}) =>
    {
      'id': 'rec-$title',
      'score': score,
      'title': title,
      'length': lengthMs,
      'disambiguation': ?disambiguation,
      'artist-credit': [
        {'name': 'Luna Ray', 'joinphrase': ' feat. '},
        {'name': 'Echo'},
      ],
      'first-release-date': '2021-04-01',
      'releases': releases,
      'tags': tags,
    };

Map<String, Object?> release(String id, String title,
        {String status = 'Official',
        String primary = 'Album',
        List<String> secondary = const [],
        String? date,
        String track = '4'}) =>
    {
      'id': id,
      'title': title,
      'status': status,
      'date': ?date,
      'release-group': {
        'id': 'rg-$id',
        'primary-type': primary,
        'secondary-types': secondary,
      },
      'media': [
        {
          'position': 1,
          'track': [
            {'number': track}
          ]
        }
      ],
    };

void main() {
  group('recordingSearch', () {
    test('narrows by artist when known, strips Lucene syntax', () {
      final u = recordingSearch(title: 'Song (Live) [2010]', artist: 'AC/DC');
      expect(u.queryParameters['query'], 'recording:"Song Live 2010" AND artist:"AC DC"');
      expect(u.queryParameters['fmt'], 'json');
    });
    test('title only', () {
      expect(recordingSearch(title: 'x').queryParameters['query'], 'recording:"x"');
    });
  });

  group('releaseLabel', () {
    test('kinds of release, in the words a person would use', () {
      expect(releaseLabel(recordingTitle: 'X', secondaryTypes: ['Live']), 'Live');
      expect(releaseLabel(recordingTitle: 'X (Acoustic)'), 'Acoustic');
      expect(releaseLabel(recordingTitle: 'X', disambiguation: 'remix'), 'Remix');
      expect(releaseLabel(recordingTitle: 'X', primaryType: 'Single'), 'Single');
      expect(releaseLabel(recordingTitle: 'X', secondaryTypes: ['Compilation']), 'Compilation');
      expect(releaseLabel(recordingTitle: 'X', status: 'Bootleg'), 'Bootleg');
      expect(releaseLabel(recordingTitle: 'X', status: 'Official', primaryType: 'Album'),
          'Official Release');
    });
  });

  group('parseRecordings', () {
    final body = jsonEncode({
      'recordings': [
        recording(title: 'Midnight Waves', lengthMs: 400000, releases: [
          release('r-live', 'Live at Night', secondary: ['Live'], date: '2023'),
        ]),
        recording(
          title: 'Midnight Waves',
          lengthMs: 225000,
          releases: [
            release('r-album', 'Tides', date: '2023-05-02'),
            release('r-album2', 'Tides', date: '2023-06-01'), // a re-pressing
            release('r-comp', 'Chill 2024', secondary: ['Compilation']),
          ],
          tags: [
            {'name': 'ambient', 'count': 3},
            {'name': 'electronic', 'count': 7},
          ],
        ),
      ],
    });

    test('ranks the take whose length matches the file first', () {
      final c = parseRecordings(body, fileSeconds: 225);
      expect(c.first.label, 'Official Release');
      expect(c.first.tags.album, 'Tides');
      expect(c.first.releaseId, 'r-album');
      expect(c.first.releaseGroupId, 'rg-r-album');
    });

    test('fills every field it can', () {
      final t = parseRecordings(body, fileSeconds: 225).first.tags;
      expect(t.artist, 'Luna Ray feat. Echo');
      expect(t.title, 'Midnight Waves');
      expect(t.year, 2023);
      expect(t.trackNumber, 4);
      expect(t.genre, 'Electronic'); // the most-voted tag
      expect(t.albumArtist, 'Luna Ray feat. Echo');
    });

    test('collapses re-pressings that would write the same tags', () {
      final albums = parseRecordings(body, fileSeconds: 225)
          .where((c) => c.tags.album == 'Tides')
          .toList();
      expect(albums, hasLength(1));
    });

    test('a compilation credits Various Artists when the release says nothing', () {
      final comp = parseRecordings(body, fileSeconds: 225)
          .firstWhere((c) => c.label == 'Compilation');
      expect(comp.tags.albumArtist, 'Various Artists');
    });

    test('a wrong-length take still appears, lower down', () {
      final c = parseRecordings(body, fileSeconds: 225);
      expect(c.last.label, 'Live');
    });

    test('garbage in, nothing out', () {
      expect(parseRecordings('not json'), isEmpty);
      expect(parseRecordings('[]'), isEmpty);
      expect(parseRecordings('{"recordings": [{"title": 5}]}'), isEmpty);
    });
  });

  group('searchTerms', () {
    test('real tags beat the filename', () {
      final t = searchTerms(const TagSet(title: 'Tagged'),
          const TagSet(title: 'Name', artist: 'From Name'))!;
      expect(t.title, 'Tagged');
      expect(t.artist, 'From Name');
    });
    test('nothing to search for', () {
      expect(searchTerms(TagSet.empty, TagSet.empty), isNull);
    });
  });

  group('Last.fm', () {
    test('keeps genre-like tags only', () {
      final body = jsonEncode({
        'toptags': {
          'tag': [
            {'name': 'seen live'},
            {'name': 'shoegaze'},
            {'name': '90s'},
            {'name': 'dream pop'},
            {'name': 'favorites'},
            {'name': 'indie'},
            {'name': 'rock'},
          ]
        }
      });
      expect(parseTopTags(body), ['Shoegaze', 'Dream pop', 'Indie']);
      expect(parseTopTags('nope'), isEmpty);
    });
  });

  group('Pacer', () {
    test('spaces calls by the interval and serves them in order', () async {
      var now = DateTime(2026);
      final slept = <Duration>[];
      final p = Pacer(
        interval: const Duration(seconds: 1),
        clock: () => now,
        sleep: (d) async {
          slept.add(d);
          now = now.add(d);
        },
      );
      await Future.wait([p.wait(), p.wait(), p.wait()]);
      expect(slept, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    });
  });

  group('JsonClient', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mp3sorter-cache'));
    tearDown(() => dir.deleteSync(recursive: true));

    Pacer fast() => Pacer(interval: Duration.zero);

    test('caches successes and serves them offline', () async {
      var calls = 0;
      final cache = LookupCache(File('${dir.path}/c.json'));
      final online = JsonClient(
        fetch: (u) async {
          calls++;
          return FetchResult(200, Uint8List.fromList(utf8.encode('{"ok":1}')));
        },
        cache: cache,
        pacer: fast(),
      );
      final url = Uri.https('example.org', '/x');
      expect((await online.get(url)).$1, LookupStatus.ok);
      await cache.save();

      final offline = JsonClient(
        fetch: (u) async => throw const SocketException('no network'),
        cache: LookupCache(File('${dir.path}/c.json')),
        pacer: fast(),
      );
      final (status, body) = await offline.get(url);
      expect(status, LookupStatus.cached);
      expect(body, '{"ok":1}');
      expect(calls, 1);
      expect((await offline.get(Uri.https('example.org', '/y'))).$1,
          LookupStatus.offline);
    });

    test('a 404 is "no match" and is not cached', () async {
      final cache = LookupCache(null);
      final c = JsonClient(
        fetch: (u) async => FetchResult(404, Uint8List(0)),
        cache: cache,
        pacer: fast(),
      );
      expect((await c.get(Uri.https('e.org', '/'))).$1, LookupStatus.noMatch);
      expect(cache.length, 0);
    });

    test('a corrupt cache file is an empty cache', () async {
      final f = File('${dir.path}/bad.json')..writeAsStringSync('{{{');
      final cache = LookupCache(f);
      await cache.load();
      expect(cache.length, 0);
    });

    test('the cache keeps only the newest entries', () {
      final cache = LookupCache(null, maxEntries: 2)
        ..put('a', '1')
        ..put('b', '2')
        ..put('c', '3');
      expect(cache.get('a'), isNull);
      expect(cache.get('c'), '3');
    });
  });

  group('sniffImageType', () {
    test('jpeg and png by magic bytes', () {
      expect(sniffImageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(9, 0)])), 'image/jpeg');
      expect(sniffImageType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, ...List.filled(8, 0)])), 'image/png');
      expect(sniffImageType(Uint8List.fromList(List.filled(12, 0))), isNull);
      expect(sniffImageType(Uint8List(3)), isNull);
    });
  });
}
