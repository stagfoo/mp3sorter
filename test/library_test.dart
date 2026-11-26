import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/library.dart';
import 'package:mp3sorter/core/store.dart';
import 'package:mp3sorter/core/tags.dart';

void main() {
  group('ordering', () {
    test('natural order within a folder', () {
      expect(orderTracks(['/a/10 x.mp3', '/a/2 x.mp3', '/a/1 x.mp3']),
          ['/a/1 x.mp3', '/a/2 x.mp3', '/a/10 x.mp3']);
    });
    test('folders stay together', () {
      expect(
          orderTracks(['/b/1.mp3', '/a/2.mp3', '/b/0.mp3', '/a/1.mp3']),
          ['/a/1.mp3', '/a/2.mp3', '/b/0.mp3', '/b/1.mp3']);
    });
  });

  test('hidden folders and temp files are ignored', () {
    expect(isIgnoredPath('.thumbnails/x.mp3'), isTrue);
    expect(isIgnoredPath('Album/.trash/x.mp3'), isTrue);
    expect(isIgnoredPath('Album/.x.mp3.mp3sorter-tmp.mp3'), isTrue);
    expect(isIgnoredPath('Album/x.mp3'), isFalse);
  });

  group('pickFolderCover', () {
    test('a named cover wins', () {
      expect(pickFolderCover(['/a/scan2.jpg', '/a/Folder.jpg', '/a/cover.png']),
          '/a/cover.png');
    });
    test('a single image is the cover', () {
      expect(pickFolderCover(['/a/whatever.jpg']), '/a/whatever.jpg');
    });
    test('many unnamed images are not guessed at', () {
      expect(pickFolderCover(['/a/01.jpg', '/a/02.jpg']), isNull);
    });
    test('non-images are ignored', () {
      expect(pickFolderCover(['/a/cover.txt', '/a/folder.webp']), isNull);
    });
  });

  group('batchTargets', () {
    final q = ['/a/1.mp3', '/a/2.mp3', '/a/3.mp3', '/b/1.mp3'];
    test('the rest of the same folder', () {
      expect(batchTargets(q, 0, (_) => true), [1, 2]);
    });
    test('skips tracks already done', () {
      expect(batchTargets(q, 0, (p) => p != '/a/2.mp3'), [2]);
    });
    test('stops at the folder boundary', () {
      expect(batchTargets(q, 2, (_) => true), isEmpty);
    });
    test('out of range is empty', () {
      expect(batchTargets(q, 9, (_) => true), isEmpty);
    });
  });

  group('folder scanning', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mp3sorter-scan'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('finds audio, skips hidden folders, respects the subfolder switch', () async {
      File('${dir.path}/b.mp3').createSync();
      File('${dir.path}/notes.txt').createSync();
      Directory('${dir.path}/Album').createSync();
      File('${dir.path}/Album/1.flac').createSync();
      Directory('${dir.path}/.thumbnails').createSync();
      File('${dir.path}/.thumbnails/t.mp3').createSync();
      expect((await scanFolder(dir.path)).map((p) => p.substring(dir.path.length)),
          ['/b.mp3', '/Album/1.flac']);
      expect(await scanFolder(dir.path, recursive: false), ['${dir.path}/b.mp3']);
    });

    test('folderCover reads and types the image', () async {
      File('${dir.path}/folder.jpg')
          .writeAsBytesSync([0xFF, 0xD8, 0xFF, ...List.filled(20, 1)]);
      final c = await folderCover(dir.path);
      expect(c!.mimeType, 'image/jpeg');
    });

    test('a file pretending to be an image is not a cover', () async {
      File('${dir.path}/cover.jpg').writeAsStringSync('not really');
      expect(await folderCover(dir.path), isNull);
    });
  });

  group('store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mp3sorter-store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('fnv1a is stable and distinguishes paths', () {
      expect(fnv1a('/sdcard/Music'), fnv1a('/sdcard/Music'));
      expect(fnv1a('/sdcard/Music'), isNot(fnv1a('/sdcard/Music2')));
      expect(fnv1a('x'), hasLength(16));
    });

    test('session progress survives a reload', () async {
      final s = await Session.load(dir, '/m');
      s.set('/m/a.mp3', TrackStatus.accepted);
      s.set('/m/b.mp3', TrackStatus.skipped);
      s.set('/m/c.mp3', TrackStatus.skipped);
      s.set('/m/c.mp3', TrackStatus.pending);
      await s.save();
      final again = await Session.load(dir, '/m');
      expect(again.of('/m/a.mp3'), TrackStatus.accepted);
      expect(again.of('/m/b.mp3'), TrackStatus.skipped);
      expect(again.isPending('/m/c.mp3'), isTrue);
      expect((await Session.load(dir, '/other')).status, isEmpty);
    });

    test('journal groups undo together, newest first, and cleans up', () async {
      final j = await Journal.load(dir);
      await j.record(group: 'g1', path: '/a', before: const TagSet(title: 'A'), coversBefore: 0);
      await j.record(
          group: 'g2',
          path: '/b',
          before: const TagSet(title: 'B'),
          coversBefore: 1,
          originalTagBlock: Uint8List.fromList([1, 2, 3]));
      await j.record(group: 'g2', path: '/c', before: TagSet.empty, coversBefore: 0);

      final reloaded = await Journal.load(dir);
      final last = reloaded.lastGroup();
      expect(last.map((e) => e.path), ['/c', '/b']);
      expect(await reloaded.blockOf(last[1]), [1, 2, 3]);

      final blockPath = last[1].blockFile!;
      for (final e in last) {
        await reloaded.remove(e);
      }
      expect(File(blockPath).existsSync(), isFalse);
      expect(reloaded.lastGroup().single.path, '/a');
    });

    test('a no-op entry round-trips and undoes with its group', () async {
      final j = await Journal.load(dir);
      await j.record(group: 'g', path: '/w', before: TagSet.empty, coversBefore: 0);
      await j.record(group: 'g', path: '/n', before: TagSet.empty, coversBefore: 1, noop: true);
      final again = await Journal.load(dir);
      expect(again.lastGroup().map((e) => (e.path, e.noop)), [('/n', true), ('/w', false)]);
    });

    test('journal drops the oldest beyond its limit, with their blocks', () async {
      final j = Journal(Directory('${dir.path}/undo'), maxEntries: 1);
      final first = await j.record(
          group: 'a', path: '/a', before: TagSet.empty, coversBefore: 0,
          originalTagBlock: Uint8List.fromList([1]));
      await j.record(group: 'b', path: '/b', before: TagSet.empty, coversBefore: 0);
      expect(j.entries.single.path, '/b');
      expect(File(first.blockFile!).existsSync(), isFalse);
    });

    test('settings remember recent folders, newest first, without repeats', () async {
      final s = await Settings.load(dir);
      s.touchFolder('/a');
      s.touchFolder('/b');
      s.touchFolder('/a');
      s.lastFmKey = 'k';
      await s.save();
      final again = await Settings.load(dir);
      expect(again.recentFolders, ['/a', '/b']);
      expect(again.lastFmKey, 'k');
    });
  });
}
