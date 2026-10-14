/// Name inference, duplicate grouping and plan building.
///
/// These are the parts that decide what happens to five thousand
/// irreplaceable files, so the bar is every edge case that can be written
/// down: two tracks wanting one filename, a file that is both a duplicate
/// and a rename candidate, a title that is only a timestamp.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/duplicates.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/track.dart';

Track t(
  String path, {
  String? artist,
  String? title,
  int size = 1000,
  int? bitrate = 192,
  String? fingerprint,
  Duration? duration = const Duration(minutes: 3),
  List<String> genres = const [],
  String? error,
}) =>
    Track(
      path: path,
      sizeBytes: size,
      artist: artist,
      title: title,
      bitrateKbps: bitrate,
      audioFingerprint: fingerprint,
      duration: duration,
      genres: genres,
      readError: error,
    );

void main() {
  group('working out artist and title', () {
    test('tags win when they are there', () {
      final n = inferNames(t('/m/junk.mp3', artist: 'Muse', title: 'Hysteria'));
      expect(n.artist, 'Muse');
      expect(n.title, 'Hysteria');
      expect(n.fromTags, isTrue);
    });

    test('the filename is parsed when tags are missing', () {
      final n = inferNames(t('/m/Muse - Hysteria.mp3'));
      expect(n.artist, 'Muse');
      expect(n.title, 'Hysteria');
      expect(n.fromTags, isFalse);
    });

    test('underscore filenames are readable again', () {
      final n = inferNames(t('/m/carly_rae_jepsen_-_call_me_maybe.mp3'));
      expect(n.artist, 'carly rae jepsen');
      expect(n.title, 'call me maybe');
    });

    test('a leading track number is not mistaken for the artist', () {
      final n = inferNames(t('/m/05 - Muse - Hysteria.mp3'));
      expect(n.artist, 'Muse');
      expect(n.title, 'Hysteria');
    });

    test('a title containing a dash survives', () {
      final n = inferNames(t('/m/Artist - Song - Live Version.mp3'));
      expect(n.artist, 'Artist');
      expect(n.title, 'Song - Live Version');
    });

    test('a timestamp filename yields no artist rather than a made-up one',
        () {
      // The real shape of half this collection. Inventing "Unknown
      // Artist" would destroy the only clue the file has left.
      final n = inferNames(t('/m/1739349830600.mp3'));
      expect(n.artist, isNull);
      expect(n.title, '1739349830600');
      expect(n.isComplete, isFalse);
    });

    test('a tagged field still wins over a parsed one', () {
      final n = inferNames(
          t('/m/wrong - alsowrong.mp3', artist: 'Real Artist'));
      expect(n.artist, 'Real Artist');
      expect(n.title, 'alsowrong');
    });
  });

  group('making a name safe for a filesystem', () {
    test('path separators and reserved characters go', () {
      expect(safeComponent('AC/DC'), 'AC_DC');
      expect(safeComponent('What?: A Song'), contains('_'));
      expect(safeComponent('a\\b'), 'a_b');
    });

    test('trailing dots and spaces go', () {
      // Windows strips them silently and then cannot find the file.
      expect(safeComponent('Album.'), 'Album');
      expect(safeComponent('Album '), 'Album');
    });

    test('over-long names are cut', () {
      final long = 'x' * 400;
      expect(safeComponent(long).length, lessThanOrEqualTo(120));
    });

    test('a name that reduces to nothing becomes a placeholder', () {
      // "..", left alone, would escape the target directory.
      expect(safeComponent('...'), isNot('..'));
      expect(safeComponent(''), '_');
      expect(safeComponent('..'), '_');
    });

    test('unicode is kept', () {
      expect(safeComponent('Sigur Rós'), 'Sigur Rós');
      expect(safeComponent('東京事変'), '東京事変');
    });
  });

  group('duplicates', () {
    test('identical files are grouped', () {
      final g = findDuplicates([
        t('/a/x.mp3', artist: 'A', title: 'X', fingerprint: 'f1', size: 100),
        t('/b/x.mp3', artist: 'A', title: 'X', fingerprint: 'f1', size: 100),
      ]);
      expect(g, hasLength(1));
      expect(g.first.kind, DuplicateKind.identicalFile);
    });

    test('same audio with different tags is found', () {
      // The commonest real duplicate, and the one a size comparison
      // misses: the sizes differ precisely because the tags do.
      final g = findDuplicates([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria', fingerprint: 'f',
            size: 5000),
        t('/b.mp3', artist: 'muse', title: 'hysteria', fingerprint: 'f',
            size: 5240),
      ]);
      expect(g, hasLength(1));
      expect(g.first.kind, DuplicateKind.sameAudio);
    });

    test('the same song at two bitrates is found by name', () {
      final g = findDuplicates([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria', bitrate: 128,
            fingerprint: 'f1'),
        t('/b.mp3', artist: 'Muse', title: 'Hysteria', bitrate: 320,
            fingerprint: 'f2'),
      ]);
      expect(g, hasLength(1));
      expect(g.first.kind, DuplicateKind.sameSong);
      expect(g.first.keep.bitrateKbps, 320);
    });

    test('a file lands in only one group', () {
      // Otherwise the counts on screen add up to more than the collection.
      final groups = findDuplicates([
        t('/a.mp3', artist: 'A', title: 'X', fingerprint: 'f', size: 10),
        t('/b.mp3', artist: 'A', title: 'X', fingerprint: 'f', size: 10),
        t('/c.mp3', artist: 'A', title: 'X', fingerprint: 'other'),
      ]);
      final all = groups.expand((g) => g.tracks).map((t) => t.path).toList();
      expect(all.length, all.toSet().length);
    });

    test('different-length songs sharing a title are not duplicates', () {
      // A radio edit and an album version really are different files.
      final g = findDuplicates([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria',
            duration: const Duration(minutes: 3), fingerprint: 'f1'),
        t('/b.mp3', artist: 'Muse', title: 'Hysteria',
            duration: const Duration(minutes: 7), fingerprint: 'f2'),
      ]);
      expect(g, isEmpty);
    });

    test('a slight duration difference is tolerated', () {
      final g = findDuplicates([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria',
            duration: const Duration(seconds: 200), fingerprint: 'f1'),
        t('/b.mp3', artist: 'Muse', title: 'Hysteria',
            duration: const Duration(seconds: 204), fingerprint: 'f2'),
      ]);
      expect(g, hasLength(1));
    });

    test('unrelated files are not grouped', () {
      expect(
        findDuplicates([
          t('/a.mp3', artist: 'Muse', title: 'Hysteria', fingerprint: 'f1'),
          t('/b.mp3', artist: 'Tool', title: 'Vicarious', fingerprint: 'f2'),
        ]),
        isEmpty,
      );
    });

    test('an empty collection is empty, not a crash', () {
      expect(findDuplicates(const []), isEmpty);
      expect(summariseDuplicates(const []).isEmpty, isTrue);
    });

    group('choosing which copy to keep', () {
      test('the better encode wins', () {
        final keep = pickKeeper([
          t('/low.mp3', bitrate: 128),
          t('/high.mp3', bitrate: 320),
        ]);
        expect(keep.path, '/high.mp3');
      });

      test('a truncated copy loses to a complete one', () {
        final keep = pickKeeper([
          t('/short.mp3', bitrate: 320, duration: const Duration(seconds: 30)),
          t('/full.mp3', bitrate: 320, duration: const Duration(minutes: 4)),
        ]);
        expect(keep.path, '/full.mp3');
      });

      test('a tagged copy beats an untagged one', () {
        final keep = pickKeeper([
          t('/untagged.mp3'),
          t('/tagged.mp3', artist: 'Muse', title: 'Hysteria'),
        ]);
        expect(keep.path, '/tagged.mp3');
      });

      test('a filed copy beats a loose one', () {
        final keep = pickKeeper([
          t('/m/a/b/c/deep.mp3'),
          t('/m/shallow.mp3'),
        ]);
        expect(keep.path, '/m/shallow.mp3');
      });

      test('the choice does not depend on input order', () {
        final a = t('/a.mp3', bitrate: 320);
        final b = t('/b.mp3', bitrate: 320);
        expect(pickKeeper([a, b]).path, pickKeeper([b, a]).path);
      });
    });
  });

  group('building a plan', () {
    const opts = PlanOptions(root: '/music');

    test('a tagged track is filed as Artist/Title', () {
      final p = buildPlan(
        [t('/in/junk.mp3', artist: 'Muse', title: 'Hysteria')],
        opts,
      );
      expect(p.moves.single.targetPath, '/music/Muse/Hysteria.mp3');
    });

    test('a file already in the right place is left alone', () {
      final p = buildPlan(
        [t('/music/Muse/Hysteria.mp3', artist: 'Muse', title: 'Hysteria')],
        opts,
      );
      expect(p.moves, isEmpty);
    });

    test('a track with no artist is reported, not filed under Unknown', () {
      final p = buildPlan([t('/in/1739349830600.mp3')], opts);
      expect(p.moves, isEmpty);
      expect(p.unsortable, hasLength(1));
    });

    test('two tracks wanting one name do not collide', () {
      final p = buildPlan([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria', bitrate: 320),
        t('/b.mp3', artist: 'Muse', title: 'Hysteria', bitrate: 128),
      ], opts);
      final targets = p.moves.map((m) => m.targetPath).toSet();
      expect(targets, hasLength(2), reason: 'one would overwrite the other');
      expect(targets.any((x) => x!.contains('128k')), isTrue,
          reason: 'the suffix should say what the second copy is');
    });

    test('collisions are detected case-insensitively', () {
      // They coexist on ext4 and collide on a FAT card.
      final p = buildPlan([
        t('/a.mp3', artist: 'Muse', title: 'Hysteria'),
        t('/b.mp3', artist: 'muse', title: 'hysteria'),
      ], const PlanOptions(root: '/music', standardiseArtists: false));
      final lowered =
          p.moves.map((m) => m.targetPath!.toLowerCase()).toList();
      expect(lowered.toSet().length, lowered.length);
    });

    test('artist spellings are standardised across the collection', () {
      final p = buildPlan([
        t('/a.mp3', artist: 'The Beatles', title: 'One'),
        t('/b.mp3', artist: 'The Beatles', title: 'Two'),
        t('/c.mp3', artist: 'beatles', title: 'Three'),
      ], opts);
      expect(p.artistMerges.keys, contains('The Beatles'));
      for (final m in p.moves) {
        expect(m.targetPath, startsWith('/music/The Beatles/'));
      }
    });

    test('a low-bitrate file is NOT tagged', () {
      // The behaviour this version removed. Quality is computed at scan
      // time and shown; writing it would spend a real metadata field on
      // something recomputable in milliseconds.
      final p = buildPlan(
        [t('/a.mp3', artist: 'A', title: 'B', bitrate: 64)],
        opts,
      );
      expect(p.retags.where((r) => r.genres != null), isEmpty);
    });

    test('a marker written by an older version is taken back', () {
      final p = buildPlan([
        t('/a.mp3',
            artist: 'A', title: 'B', bitrate: 64,
            genres: ['Rock', 'low quality']),
      ], opts);
      expect(p.retags.single.genres, ['Rock']);
      expect(p.retags.single.reason, contains('remove'));
    });

    test('a file carrying no marker gets no genre change', () {
      final p = buildPlan([
        t('/music/A/B.mp3',
            artist: 'A', title: 'B', bitrate: 64, genres: ['Rock']),
      ], const PlanOptions(root: '/music'));
      expect(p.retags.where((r) => r.genres != null), isEmpty);
    });

    test('the cleanup can be turned off', () {
      final p = buildPlan([
        t('/a.mp3',
            artist: 'A', title: 'B', genres: ['Rock', 'low quality']),
      ], const PlanOptions(root: '/music', cleanQualityTags: false));
      expect(p.retags.where((r) => r.genres != null), isEmpty);
    });

    test('nothing is planned when nothing needs doing', () {
      final p = buildPlan([
        t('/music/Muse/Hysteria.mp3',
            artist: 'Muse', title: 'Hysteria', bitrate: 320),
      ], opts);
      expect(p.isEmpty, isTrue);
    });

    test('duplicate removal is off unless asked for', () {
      final tracks = [
        t('/a.mp3', artist: 'A', title: 'B', fingerprint: 'f'),
        t('/b.mp3', artist: 'A', title: 'B', fingerprint: 'f'),
      ];
      expect(buildPlan(tracks, opts).trashes, isEmpty);
      expect(
        buildPlan(tracks,
                const PlanOptions(root: '/music', removeDuplicates: true))
            .trashes,
        hasLength(1),
      );
    });

    test('a file being trashed is not also planned a move', () {
      // Two actions on one path is how a plan half-applies.
      final p = buildPlan([
        t('/a.mp3', artist: 'A', title: 'B', fingerprint: 'f', bitrate: 320),
        t('/b.mp3', artist: 'A', title: 'B', fingerprint: 'f', bitrate: 320),
      ], const PlanOptions(root: '/music', removeDuplicates: true));
      final trashed = p.trashes.map((x) => x.path).toSet();
      expect(p.moves.where((m) => trashed.contains(m.path)), isEmpty);
    });

    test('deletions go to trash, never to nowhere', () {
      final p = buildPlan([
        t('/a.mp3', artist: 'A', title: 'B', fingerprint: 'f'),
        t('/b.mp3', artist: 'A', title: 'B', fingerprint: 'f'),
      ], const PlanOptions(root: '/music', removeDuplicates: true));
      expect(p.trashes.single.targetPath, contains('.mp3sorter-trash'));
    });

    test('an unreadable file is reported and never acted on', () {
      final p = buildPlan(
        [t('/broken.mp3', error: 'not an mp3')],
        opts,
      );
      expect(p.unsortable, hasLength(1));
      expect(p.actionCount, 0);
    });

    test('turning features off produces no actions of that kind', () {
      final tracks = [t('/a.mp3', artist: 'A', title: 'B', bitrate: 64)];
      final noRename = buildPlan(
          tracks, const PlanOptions(root: '/m', renameFiles: false));
      expect(noRename.moves, isEmpty);
      final noTags = buildPlan(
          tracks, const PlanOptions(root: '/m', writeTags: false));
      expect(noTags.retags, isEmpty);
    });

    group('rescanning a folder that has already been sorted', () {
      // The app files into a _sorted subfolder, so on a rescan that is
      // the plan root and the already-filed tracks sit directly under it.
      const sortedOpts = PlanOptions(root: '/music/_sorted');
      // The 1.0.x bug, reproduced. A previous run left three files with
      // the same tags under disambiguated names. Rescanning planned the
      // suffixed ones straight onto the plain one, which was skipped
      // without reserving its name — and every move failed at apply time
      // with "something already exists". 120 of them on a real device.
      final alreadySorted = [
        t('/music/_sorted/Babymetal/Megitsune.mp3',
            artist: 'Babymetal', title: 'Megitsune', bitrate: 320,
            fingerprint: 'f1'),
        t('/music/_sorted/Babymetal/Megitsune (134k).mp3',
            artist: 'Babymetal', title: 'Megitsune', bitrate: 134,
            fingerprint: 'f2'),
        t('/music/_sorted/Babymetal/Megitsune (2).mp3',
            artist: 'Babymetal', title: 'Megitsune', bitrate: 192,
            fingerprint: 'f3'),
      ];

      test('nothing is planned onto the file that is staying put', () {
        final p = buildPlan(alreadySorted, sortedOpts);
        const settled = '/music/_sorted/babymetal/megitsune.mp3';
        for (final m in p.moves) {
          expect(m.targetPath!.toLowerCase(), isNot(settled),
              reason: '${m.path} would land on a file that is not moving');
        }
      });

      test('the already-correct file is recorded as staying', () {
        final p = buildPlan(alreadySorted, sortedOpts);
        expect(p.stationaryPaths,
            contains('/music/_sorted/babymetal/megitsune.mp3'));
      });

      test('every target is distinct', () {
        final p = buildPlan(alreadySorted, sortedOpts);
        final targets =
            p.moves.map((m) => m.targetPath!.toLowerCase()).toList();
        expect(targets.toSet().length, targets.length);
      });

      test('the plan validates clean', () {
        expect(validatePlan(buildPlan(alreadySorted, sortedOpts)), isEmpty);
      });

      test('a second run over the result changes nothing', () {
        // Convergence. A tidier that keeps finding work on an already
        // tidy folder is one you stop trusting.
        final first = buildPlan(alreadySorted, sortedOpts);
        final after = <Track>[];
        for (final track in alreadySorted) {
          final move = first.moves
              .where((m) => m.path == track.path)
              .cast<PlannedAction?>()
              .firstWhere((_) => true, orElse: () => null);
          after.add(move == null
              ? track
              : t(move.targetPath!,
                  artist: track.artist,
                  title: track.title,
                  bitrate: track.bitrateKbps,
                  fingerprint: track.audioFingerprint));
        }
        expect(buildPlan(after, sortedOpts).moves, isEmpty);
      });
    });

    test('a file may move onto a name another file is vacating', () {
      // The conservative fix would be to treat every current path as
      // occupied, which would suffix files needlessly on a reorganise.
      final p = buildPlan([
        t('/music/_sorted/A/One.mp3', artist: 'A', title: 'Two'),
        t('/music/_sorted/A/Two.mp3', artist: 'A', title: 'Three'),
      ], const PlanOptions(root: '/music/_sorted'));
      final targets = p.moves.map((m) => m.targetPath).toList();
      expect(targets, contains('/music/_sorted/A/Two.mp3'));
      expect(targets.every((x) => !x!.contains('(2)')), isTrue);
    });

    test('an empty collection plans nothing', () {
      expect(buildPlan(const [], opts).isEmpty, isTrue);
    });
  });

  group('validating a plan before it runs', () {
    test('a clean plan has no problems', () {
      final p = buildPlan([
        t('/a.mp3', artist: 'A', title: 'One'),
        t('/b.mp3', artist: 'A', title: 'Two'),
      ], const PlanOptions(root: '/m'));
      expect(validatePlan(p), isEmpty);
    });

    test('two moves onto one target are caught', () {
      const plan = Plan(
        moves: [
          PlannedAction(
              kind: ActionKind.move, path: '/a.mp3', targetPath: '/m/x.mp3'),
          PlannedAction(
              kind: ActionKind.move, path: '/b.mp3', targetPath: '/m/x.mp3'),
        ],
        retags: [],
        trashes: [],
        artistMerges: {},
        unsortable: [],
      );
      expect(validatePlan(plan), isNotEmpty);
    });

    test('a file both moved and trashed is caught', () {
      const plan = Plan(
        moves: [
          PlannedAction(
              kind: ActionKind.move, path: '/a.mp3', targetPath: '/m/x.mp3'),
        ],
        retags: [],
        trashes: [
          PlannedAction(
              kind: ActionKind.trash, path: '/a.mp3', targetPath: '/t/a.mp3'),
        ],
        artistMerges: {},
        unsortable: [],
      );
      expect(validatePlan(plan), isNotEmpty);
    });
  });
}
