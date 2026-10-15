/// The saved index, and editing it instead of rescanning.
///
/// These rules decide whether the app's picture of five thousand files
/// stays true to the disk. Two kinds of failure matter, and they are not
/// symmetrical:
///
///  * **Thinking a file is unchanged when it is not** is the dangerous
///    one. The app then plans from stale information, which is how "0
///    applied, 249 failed" happened.
///  * **Thinking a file changed when it did not** costs 3.7ms.
///
/// So every uncertain case here resolves to "read it again".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/apply.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/track.dart';
import 'package:mp3sorter/track_index.dart';

Track t(
  String path, {
  int size = 1000,
  int mtime = 1700000000000,
  String? artist,
  String? title,
  String? album,
  List<String> genres = const [],
}) =>
    Track(
      path: path,
      sizeBytes: size,
      modifiedMs: mtime,
      artist: artist,
      title: title,
      album: album,
      genres: genres,
      bitrateKbps: 192,
    );

TrackIndex indexOf(
  List<Track> tracks, {
  String root = '/m',
  Map<String, String> art = const {},
  Set<String> checked = const {},
  Map<String, String> folderImages = const {},
}) =>
    TrackIndex(
      rootPath: root,
      scannedAt: DateTime(2026, 10, 16),
      tracks: tracks,
      embeddedArt: art,
      artChecked: checked,
      folderImages: folderImages,
    );

JournalEntry entry(
  ActionKind kind,
  String path, {
  String? target,
  String? error,
}) =>
    JournalEntry(
      kind: kind,
      path: path,
      targetPath: target,
      at: DateTime(2026, 10, 16),
      error: error,
    );

void main() {
  group('deciding a file is unchanged', () {
    test('same size and same time is a match', () {
      expect(t('/m/a.mp3', size: 1000, mtime: 5).matchesStamp(1000, 5), isTrue);
    });

    test('a different size is not', () {
      // Catches an edit that changed the length.
      expect(t('/m/a.mp3', size: 1000, mtime: 5).matchesStamp(1001, 5), isFalse);
    });

    test('a different time is not', () {
      // Catches an edit that replaced as many bytes as it removed —
      // which is what a tag rewrite often does.
      expect(t('/m/a.mp3', size: 1000, mtime: 5).matchesStamp(1000, 6), isFalse);
    });

    test('an unknown time never matches, whatever the size says', () {
      // A track from a scan saved before stamps existed. Re-reading it
      // costs 3.7ms; trusting it could cost the whole collection.
      final old = t('/m/a.mp3', size: 1000, mtime: 0);
      expect(old.matchesStamp(1000, 0), isFalse);
      expect(old.matchesStamp(1000, 5), isFalse);
    });
  });

  group('absorbing a move', () {
    test('the track follows its file to the new path', () {
      final before = indexOf([t('/m/in/song.mp3', artist: 'Muse')]);
      final after = before.afterJournal([
        entry(ActionKind.move, '/m/in/song.mp3',
            target: '/m/Muse/Hysteria.mp3'),
      ]);

      expect(after.tracks.single.path, '/m/Muse/Hysteria.mp3');
      expect(after.tracks.single.artist, 'Muse',
          reason: 'a move changes where a file is, not what is in it');
    });

    test('its stamp is cleared, so the next scan re-reads it', () {
      // A copy-and-delete across filesystems — the normal path on this
      // device — gives the new file a new modification time. A stamp
      // that stayed optimistic would mean a changed file never being
      // read again.
      final after = indexOf([t('/m/a.mp3', mtime: 5)]).afterJournal([
        entry(ActionKind.move, '/m/a.mp3', target: '/m/b.mp3'),
      ]);
      expect(after.tracks.single.modifiedMs, 0);
    });

    test('a failed move leaves the index exactly as it was', () {
      // The applier guarantees a failure leaves the file where it was,
      // including undoing a copy whose original could not be removed.
      final before = indexOf([t('/m/a.mp3')]);
      final after = before.afterJournal([
        entry(ActionKind.move, '/m/a.mp3',
            target: '/m/b.mp3', error: 'something already exists'),
      ]);
      expect(after.tracks.single.path, '/m/a.mp3');
      expect(after.tracks.single.modifiedMs, before.tracks.single.modifiedMs);
    });

    test('its art entry follows it too', () {
      final after = indexOf(
        [t('/m/a.mp3')],
        art: {'/m/a.mp3': 'image/jpeg'},
        checked: {'/m/a.mp3'},
      ).afterJournal([
        entry(ActionKind.move, '/m/a.mp3', target: '/m/b.mp3'),
      ]);

      expect(after.embeddedArt, {'/m/b.mp3': 'image/jpeg'});
      expect(after.artChecked, {'/m/b.mp3'},
          reason: 'otherwise the art pass re-reads a file it knows about');
    });

    test('the result stays in path order', () {
      // buildPlan's collision handling depends on the order it is
      // given, so an edited index must plan identically to a fresh scan.
      final after = indexOf([
        t('/m/a.mp3'),
        t('/m/b.mp3'),
        t('/m/c.mp3'),
      ]).afterJournal([
        entry(ActionKind.move, '/m/a.mp3', target: '/m/z.mp3'),
      ]);
      expect(after.tracks.map((x) => x.path), ['/m/b.mp3', '/m/c.mp3', '/m/z.mp3']);
    });

    test('a move whose journal entry has no target is ignored', () {
      final after = indexOf([t('/m/a.mp3')])
          .afterJournal([entry(ActionKind.move, '/m/a.mp3')]);
      expect(after.tracks.single.path, '/m/a.mp3');
    });
  });

  group('absorbing a retag', () {
    test('the new values come from the plan, not the journal', () {
      // The journal records what the tags *were*, because that is what
      // undo needs. Without the plan the index would keep the old
      // values and the same retag would be planned again, which looks
      // exactly like the write having silently failed.
      final plan = Plan(
        moves: const [],
        retags: const [
          PlannedAction(
            kind: ActionKind.retag,
            path: '/m/a.mp3',
            artist: 'Wolfmother',
            title: 'Woman',
          ),
        ],
        trashes: const [],
        artistMerges: const {},
        unsortable: const [],
      );

      final after = indexOf([t('/m/a.mp3', artist: 'wolfmother', title: 'woman')])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')], applied: plan);

      expect(after.tracks.single.artist, 'Wolfmother');
      expect(after.tracks.single.title, 'Woman');
    });

    test('a field the plan left alone is left alone', () {
      final plan = Plan(
        moves: const [],
        retags: const [
          PlannedAction(
            kind: ActionKind.retag,
            path: '/m/a.mp3',
            artist: 'Muse',
          ),
        ],
        trashes: const [],
        artistMerges: const {},
        unsortable: const [],
      );
      final after = indexOf([t('/m/a.mp3', artist: 'muse', title: 'Hysteria')])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')], applied: plan);

      expect(after.tracks.single.artist, 'Muse');
      expect(after.tracks.single.title, 'Hysteria');
    });

    test('the stamp is cleared because writing tags rewrites the file', () {
      final after = indexOf([t('/m/a.mp3', mtime: 5)])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')]);
      expect(after.tracks.single.modifiedMs, 0);
    });

    test('without the plan it is still correct, just slower', () {
      // The stamp is cleared either way, so the next scan re-reads the
      // file and picks up the real tags.
      final after = indexOf([t('/m/a.mp3', artist: 'old')])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')]);
      expect(after.tracks.single.modifiedMs, 0);
      expect(after.tracks.single.artist, 'old');
    });
  });

  group('absorbing art', () {
    test('an embedded cover makes the file worth re-checking', () {
      // The mimetype is not in the journal and guessing it would mean a
      // cover.jpg holding a PNG, so the file is dropped from the
      // checked set and read once more.
      final after = indexOf(
        [t('/m/a.mp3')],
        checked: {'/m/a.mp3'},
      ).afterJournal([entry(ActionKind.embedArt, '/m/a.mp3')]);

      expect(after.artChecked, isEmpty);
      expect(after.tracks.single.modifiedMs, 0);
    });

    test('a written cover file is remembered as the folder image', () {
      final after = indexOf([t('/m/album/01.mp3')])
          .afterJournal([entry(ActionKind.writeCover, '/m/album/cover.jpg')]);
      expect(after.folderImages, {'/m/album': '/m/album/cover.jpg'});
    });

    test('a failed cover write changes nothing', () {
      final after = indexOf([t('/m/album/01.mp3')]).afterJournal([
        entry(ActionKind.writeCover, '/m/album/cover.jpg',
            error: 'a cover is already there'),
      ]);
      expect(after.folderImages, isEmpty);
    });
  });

  group('absorbing a trash', () {
    test('the track leaves the collection', () {
      final after = indexOf([t('/m/a.mp3'), t('/m/b.mp3')]).afterJournal([
        entry(ActionKind.trash, '/m/b.mp3', target: '/m/.trash/b.mp3'),
      ]);
      expect(after.tracks.map((x) => x.path), ['/m/a.mp3']);
    });

    test('its art entries go with it', () {
      final after = indexOf(
        [t('/m/a.mp3')],
        art: {'/m/a.mp3': 'image/jpeg'},
        checked: {'/m/a.mp3'},
      ).afterJournal([
        entry(ActionKind.trash, '/m/a.mp3', target: '/m/.trash/a.mp3'),
      ]);
      expect(after.embeddedArt, isEmpty);
      expect(after.artChecked, isEmpty);
    });
  });

  group('replaying a whole run', () {
    test('a retag then a move lands on the right track', () {
      // The applier writes tags before it moves, so the two entries
      // name different paths for one file. Replaying them in the order
      // written is the only way both arrive.
      final plan = Plan(
        moves: const [
          PlannedAction(
            kind: ActionKind.move,
            path: '/m/in/x.mp3',
            targetPath: '/m/Muse/Hysteria.mp3',
          ),
        ],
        retags: const [
          PlannedAction(
            kind: ActionKind.retag,
            path: '/m/in/x.mp3',
            artist: 'Muse',
            title: 'Hysteria',
          ),
        ],
        trashes: const [],
        artistMerges: const {},
        unsortable: const [],
      );

      final after = indexOf([t('/m/in/x.mp3')]).afterJournal([
        entry(ActionKind.retag, '/m/in/x.mp3'),
        entry(ActionKind.move, '/m/in/x.mp3',
            target: '/m/Muse/Hysteria.mp3'),
      ], applied: plan);

      expect(after.tracks, hasLength(1));
      expect(after.tracks.single.path, '/m/Muse/Hysteria.mp3');
      expect(after.tracks.single.artist, 'Muse');
      expect(after.tracks.single.title, 'Hysteria');
    });

    test('an index that absorbed a run plans nothing more to do', () {
      // The whole point. A run used to leave every path in the scan
      // wrong, so applying again failed on every file; now the index
      // describes where things actually are.
      final before = indexOf([
        t('/m/in/a.mp3', artist: 'Muse', title: 'Hysteria', album: 'Absolution'),
      ], root: '/m');

      const options = PlanOptions(root: '/m/_sorted', sourceRoot: '/m');
      final first = buildPlan(before.tracks, options);
      expect(first.moves, hasLength(1));

      final journal = [
        for (final m in first.moves)
          entry(ActionKind.move, m.path, target: m.targetPath),
        for (final r in first.retags) entry(ActionKind.retag, r.path),
      ];
      final after = before.afterJournal(journal, applied: first);

      final second = buildPlan(after.tracks, options);
      expect(second.moves, isEmpty,
          reason: 'nothing left to move, without a rescan');
    });

    test('many files at once', () {
      final tracks = [for (var i = 0; i < 50; i++) t('/m/in/$i.mp3')];
      final after = indexOf(tracks).afterJournal([
        for (var i = 0; i < 50; i++)
          entry(ActionKind.move, '/m/in/$i.mp3', target: '/m/out/$i.mp3'),
      ]);
      expect(after.tracks, hasLength(50));
      expect(after.tracks.every((x) => x.path.startsWith('/m/out/')), isTrue);
    });

    test('an entry for a file the index never knew is ignored', () {
      final after = indexOf([t('/m/a.mp3')]).afterJournal([
        entry(ActionKind.move, '/m/ghost.mp3', target: '/m/other.mp3'),
      ]);
      expect(after.tracks.map((x) => x.path), ['/m/a.mp3']);
    });
  });

  group('fresh stamps', () {
    test('a re-read stamp spares the file a full re-read', () {
      final after = indexOf([t('/m/a.mp3', mtime: 5)])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')])
          .withFreshStamps({'/m/a.mp3': (2048, 99)});

      expect(after.tracks.single.sizeBytes, 2048);
      expect(after.tracks.single.modifiedMs, 99);
      expect(after.tracks.single.matchesStamp(2048, 99), isTrue);
    });

    test('a file that could not be stat-ed stays due for a re-read', () {
      final after = indexOf([t('/m/a.mp3', mtime: 5)])
          .afterJournal([entry(ActionKind.retag, '/m/a.mp3')])
          .withFreshStamps(const {});
      expect(after.tracks.single.modifiedMs, 0);
    });
  });

  group('the file format', () {
    test('a round trip keeps every field', () {
      final before = indexOf(
        [t('/m/a.mp3', size: 4096, mtime: 12345, artist: 'Muse')],
        art: {'/m/a.mp3': 'image/jpeg'},
        checked: {'/m/a.mp3', '/m/b.mp3'},
        folderImages: {'/m': '/m/cover.jpg'},
      );
      final after = decodeIndex(encodeIndex(before))!;

      expect(after.rootPath, '/m');
      expect(after.tracks.single.sizeBytes, 4096);
      expect(after.tracks.single.modifiedMs, 12345);
      expect(after.tracks.single.artist, 'Muse');
      expect(after.embeddedArt, {'/m/a.mp3': 'image/jpeg'});
      expect(after.artChecked, {'/m/a.mp3', '/m/b.mp3'});
      expect(after.folderImages, {'/m': '/m/cover.jpg'});
    });

    test('a stamp survives, because the whole idea rests on it', () {
      final after = decodeIndex(encodeIndex(indexOf([t('/m/a.mp3', mtime: 77)])))!;
      expect(after.tracks.single.matchesStamp(1000, 77), isTrue);
    });

    test('one bad row costs that row', () {
      final json = '{"version":$kIndexVersion,"root":"/m","tracks":'
          '[{"path":"/m/a.mp3","size":1},{"nope":true},'
          '{"path":"/m/b.mp3","size":2}]}';
      expect(decodeIndex(json)!.tracks.map((x) => x.path),
          ['/m/a.mp3', '/m/b.mp3']);
    });

    test('an index from a newer build is rebuilt, not misread', () {
      // Its tracks could mean something different — a changed
      // fingerprint, a field the planner now relies on.
      final json = '{"version":${kIndexVersion + 1},"root":"/m","tracks":[]}';
      expect(decodeIndex(json), isNull);
    });

    test('an index from an older build is rebuilt too', () {
      expect(decodeIndex('{"version":0,"root":"/m","tracks":[]}'), isNull);
    });

    test('nonsense is null, not a crash', () {
      // It is a cache. The correct response to one that cannot be read
      // is to rebuild it, at the cost of a single slow scan.
      expect(decodeIndex('not json'), isNull);
      expect(decodeIndex('[]'), isNull);
      expect(decodeIndex(''), isNull);
      expect(decodeIndex('{"version":1,"tracks":[]}'), isNull,
          reason: 'no root means it cannot be matched to a folder');
    });

    test('art maps with odd values are dropped, not carried', () {
      final json = '{"version":$kIndexVersion,"root":"/m","tracks":[],'
          '"art":{"/m/a.mp3":"image/jpeg","/m/b.mp3":42}}';
      expect(decodeIndex(json)!.embeddedArt, {'/m/a.mp3': 'image/jpeg'});
    });
  });

  group('what the screen says', () {
    test('an untouched collection says nothing was re-read', () {
      const stats = ReuseStats(reused: 5303, read: 0, vanished: 0);
      expect(stats.everythingReused, isTrue);
      expect(stats.describe(), contains('none changed'));
    });

    test('a first scan says what it read', () {
      const stats = ReuseStats(reused: 0, read: 5303, vanished: 0);
      expect(stats.everythingReused, isFalse);
      expect(stats.describe(), '5303 files read');
    });

    test('a few changed files are reported as such', () {
      const stats = ReuseStats(reused: 5300, read: 3, vanished: 0);
      expect(stats.describe(), '3 changed, 5300 unchanged');
    });

    test('an empty folder does not pretend otherwise', () {
      const stats = ReuseStats(reused: 0, read: 0, vanished: 0);
      expect(stats.describe(), 'nothing found');
    });
  });
}
