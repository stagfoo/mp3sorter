/// Reusing a saved index, against real files in a temp directory.
///
/// The pure rules are in `track_index_test.dart`. What is left — and it
/// is the part that can silently go wrong — is whether a real
/// filesystem's size and modification time actually tell us what we
/// think they do, through a real tag write.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/apply.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/track_index.dart';

late Directory tmp;

String p(String relative) => '${tmp.path}/$relative';

/// A one-second silent MP3 with an ID3v2 tag. Real, because the point of
/// these tests is the behaviour of a real file.
File fixture(String relative) {
  final f = File(p(relative));
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(File('test/fixtures/silence.mp3').readAsBytesSync());
  return f;
}

TrackIndex indexFrom(ScanResult scan) => TrackIndex(
      rootPath: tmp.path,
      scannedAt: DateTime.now(),
      tracks: scan.tracks,
    );

/// Round-tripped through the file format, since that is how an index
/// actually arrives — a bug in the encoding would be invisible to a
/// test that kept the object in memory.
TrackIndex saved(TrackIndex index) => decodeIndex(encodeIndex(index))!;

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('mp3sorter_reuse'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('a second scan of an untouched folder', () {
    test('reads nothing and returns the same tracks', () async {
      fixture('a.mp3');
      fixture('b/c.mp3');

      final first = await scanDirectory(tmp);
      expect(first.reuse.read, 2);
      expect(first.reuse.reused, 0);

      final second = await scanDirectory(tmp, reuse: saved(indexFrom(first)));
      expect(second.reuse.read, 0, reason: 'nothing changed, nothing opened');
      expect(second.reuse.reused, 2);
      expect(second.reuse.everythingReused, isTrue);

      // And the tracks must be the same, not merely as many.
      for (var i = 0; i < 2; i++) {
        expect(second.tracks[i].path, first.tracks[i].path);
        expect(second.tracks[i].audioFingerprint,
            first.tracks[i].audioFingerprint);
        expect(second.tracks[i].bitrateKbps, first.tracks[i].bitrateKbps);
        expect(second.tracks[i].duration, first.tracks[i].duration);
      }
    });

    test('a scan records a stamp it can later match', () async {
      fixture('a.mp3');
      final scan = await scanDirectory(tmp);
      final track = scan.tracks.single;
      final stat = File(track.path).statSync();
      expect(track.matchesStamp(stat.size, stat.modified.millisecondsSinceEpoch),
          isTrue);
    });
  });

  group('a file that changed', () {
    test('a rewritten file is read again', () async {
      final file = fixture('a.mp3');
      final first = await scanDirectory(tmp);
      final index = saved(indexFrom(first));

      // A real tag write, which is what this app does to files.
      updateMetadata(file, (m) => m.setArtist('Somebody Else'));

      final second = await scanDirectory(tmp, reuse: index);
      expect(second.reuse.read, 1, reason: 'the stamp moved, so it was re-read');
      expect(second.tracks.single.artist, 'Somebody Else');
    });

    test('a file of the same length but a new time is read again', () async {
      // The case a size comparison alone would miss, and tag writes
      // produce it routinely.
      final file = fixture('a.mp3');
      final first = await scanDirectory(tmp);
      final before = file.lengthSync();

      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes, flush: true);
      file.setLastModifiedSync(
          DateTime.now().add(const Duration(minutes: 5)));
      expect(file.lengthSync(), before, reason: 'same size on purpose');

      final second = await scanDirectory(tmp, reuse: saved(indexFrom(first)));
      expect(second.reuse.read, 1);
    });

    test('a new file is read while the rest are not', () async {
      fixture('a.mp3');
      final first = await scanDirectory(tmp);
      fixture('b.mp3');

      final second = await scanDirectory(tmp, reuse: saved(indexFrom(first)));
      expect(second.reuse.read, 1);
      expect(second.reuse.reused, 1);
      expect(second.tracks, hasLength(2));
    });

    test('a deleted file is counted as gone, not carried forward', () async {
      fixture('a.mp3');
      fixture('b.mp3');
      final first = await scanDirectory(tmp);
      File(p('b.mp3')).deleteSync();

      final second = await scanDirectory(tmp, reuse: saved(indexFrom(first)));
      expect(second.tracks.map((t) => t.path), [p('a.mp3')]);
      expect(second.reuse.vanished, 1);
    });
  });

  group('an index that must not be trusted', () {
    test('one for a different folder is ignored entirely', () async {
      fixture('a.mp3');
      final first = await scanDirectory(tmp);
      final elsewhere = TrackIndex(
        rootPath: '/somewhere/else',
        scannedAt: DateTime.now(),
        tracks: first.tracks,
      );

      final second = await scanDirectory(tmp, reuse: elsewhere);
      expect(second.reuse.reused, 0,
          reason: 'matching stamps across two collections matches on nothing');
      expect(second.reuse.read, 1);
    });

    test('a trailing slash is the same folder', () async {
      fixture('a.mp3');
      final first = await scanDirectory(tmp);
      final slashed = TrackIndex(
        rootPath: '${tmp.path}/',
        scannedAt: DateTime.now(),
        tracks: first.tracks,
      );
      final second = await scanDirectory(tmp, reuse: slashed);
      expect(second.reuse.reused, 1);
    });

    test('a track with no stamp is read again', () async {
      fixture('a.mp3');
      final first = await scanDirectory(tmp);
      final stampless = indexFrom(first)
          .withTracks([first.tracks.single.copyWith(modifiedMs: 0)]);

      final second = await scanDirectory(tmp, reuse: saved(stampless));
      expect(second.reuse.read, 1);
    });
  });

  group('a run, then a rescan', () {
    test('the edited index agrees with what a rescan finds', () async {
      // The whole claim, end to end: apply a plan, edit the index from
      // the journal, and have a real rescan confirm the edit was right.
      fixture('in/one.mp3');
      fixture('in/two.mp3');

      final scan = await scanDirectory(tmp);
      final options =
          PlanOptions(root: '${tmp.path}/_sorted', sourceRoot: tmp.path);
      final plan = buildPlan(scan.tracks, options);
      expect(plan.moves, isNotEmpty);
      expect(validatePlan(plan), isEmpty);

      final journal = Journal(File(p('.journal.jsonl')));
      final result = await applyPlan(plan, journal);
      expect(result.failed, 0, reason: result.errors.join('; '));

      var index = indexFrom(scan)
          .afterJournal(await journal.read(), applied: plan);
      // The stamps a real run would re-read.
      final fresh = <String, (int, int)>{};
      for (final t in index.tracks) {
        final stat = File(t.path).statSync();
        fresh[t.path] = (stat.size, stat.modified.millisecondsSinceEpoch);
      }
      index = index.withFreshStamps(fresh);

      // Nothing left to do, without having rescanned.
      final again = buildPlan(index.tracks, options);
      expect(again.moves, isEmpty);

      // And a rescan confirms it, reading nothing.
      final rescan = await scanDirectory(tmp, reuse: saved(index));
      expect(rescan.reuse.read, 0,
          reason: 'the refreshed stamps spared every file a re-read');
      expect(
        rescan.tracks.map((t) => t.path).toList()..sort(),
        index.tracks.map((t) => t.path).toList()..sort(),
      );
    });

    test('a retagged file keeps its new tags and needs no re-read',
        () async {
      final file = fixture('a.mp3');
      final scan = await scanDirectory(tmp);

      final retag = PlannedAction(
        kind: ActionKind.retag,
        path: file.path,
        artist: 'Wolfmother',
      );
      final withRetag = Plan(
        moves: const [],
        retags: [retag],
        trashes: const [],
        artistMerges: const {},
        unsortable: const [],
      );

      final journal = Journal(File(p('.journal.jsonl')));
      final result = await applyPlan(withRetag, journal);
      expect(result.failed, 0, reason: result.errors.join('; '));

      var index = indexFrom(scan)
          .afterJournal(await journal.read(), applied: withRetag);
      expect(index.tracks.single.artist, 'Wolfmother');

      final stat = File(file.path).statSync();
      index = index.withFreshStamps(
          {file.path: (stat.size, stat.modified.millisecondsSinceEpoch)});

      final rescan = await scanDirectory(tmp, reuse: saved(index));
      expect(rescan.reuse.read, 0, reason: 'the fresh stamp matched');
      expect(rescan.tracks.single.artist, 'Wolfmother',
          reason: 'and the value the index carried was the real one');
    });
  });

  group('the art pass', () {
    test('a second pass over untouched files reads nothing', () async {
      fixture('a.mp3');
      fixture('b.mp3');
      final scan = await scanDirectory(tmp);

      final first = await scanAlbumArt(scan.tracks);
      expect(first.reusedCount, 0);
      expect(first.checked, hasLength(2));

      final index = saved(TrackIndex(
        rootPath: tmp.path,
        scannedAt: DateTime.now(),
        tracks: scan.tracks,
        embeddedArt: first.embeddedArt,
        artChecked: first.checked,
        folderImages: first.folderImages,
      ));

      final second = await scanAlbumArt(scan.tracks, reuse: index);
      expect(second.reusedCount, 2);
      expect(second.embeddedArt, first.embeddedArt);
    });

    test('a file that gained a cover is re-read, not remembered as bare',
        () async {
      // The failure the stamp check exists to stop: this app embeds a
      // cover, and the next art pass would otherwise still report the
      // file as having none.
      final file = fixture('a.mp3');
      final scan = await scanDirectory(tmp);
      final first = await scanAlbumArt(scan.tracks);
      expect(first.embeddedArt, isEmpty);

      updateMetadata(file, (m) => m.setPictures([
            Picture(
              Uint8List.fromList(
                  [0xFF, 0xD8, 0xFF, ...List.filled(200, 7)]),
              'image/jpeg',
              PictureType.coverFront,
            )
          ]));

      // Rescanned, so the track carries the new stamp.
      final rescan = await scanDirectory(tmp, reuse: saved(TrackIndex(
        rootPath: tmp.path,
        scannedAt: DateTime.now(),
        tracks: scan.tracks,
      )));

      final second = await scanAlbumArt(
        rescan.tracks,
        reuse: saved(TrackIndex(
          rootPath: tmp.path,
          scannedAt: DateTime.now(),
          tracks: scan.tracks,
          embeddedArt: first.embeddedArt,
          artChecked: first.checked,
        )),
      );

      expect(second.reusedCount, 0, reason: 'the stamp moved');
      expect(second.embeddedArt[file.path], 'image/jpeg');
    });
  });
}
