import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/id3.dart';
import 'package:mp3sorter/core/tag_io.dart';
import 'package:mp3sorter/core/tags.dart';

/// Real MPEG-1 Layer III frames: 128 kbps, 44.1 kHz, no padding — 417 bytes
/// each, about 26 ms of audio. 200 of them is a little over five seconds.
Uint8List mpegFrames([int count = 200]) {
  final b = BytesBuilder();
  for (var i = 0; i < count; i++) {
    b.add([0xFF, 0xFB, 0x90, 0x00]);
    b.add(Uint8List(413));
  }
  return b.takeBytes();
}

List<int> frame3(String id, List<int> body) {
  final n = body.length;
  return [...ascii.encode(id), (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, 0, 0, ...body];
}

Uint8List v23(List<List<int>> frames) {
  final body = [for (final f in frames) ...f, ...List.filled(64, 0)];
  return Uint8List.fromList([...ascii.encode('ID3'), 3, 0, 0, ...syncsafeBytes(body.length), ...body]);
}

final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(60, 7)]);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp3sorter-io'));
  tearDown(() => dir.deleteSync(recursive: true));

  String put(String name, Uint8List bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  List<String> leftovers() => dir
      .listSync()
      .map((e) => e.path.split('/').last)
      .where((n) => n.contains('mp3sorter-tmp'))
      .toList();

  test('a bare MP3 with no tag gets tags and a cover, and undo restores it exactly', () {
    final original = mpegFrames();
    final path = put('bare.mp3', original);

    final r = writeTagsAtomic(path,
        const TagSet(title: 'Héllo', artist: 'Luna Ray', album: 'Tides', year: 2023, trackNumber: 4),
        cover: CoverImage(jpeg, 'image/jpeg'));
    expect(r.ok, isTrue, reason: r.error);

    final info = readTrackInfo(path);
    expect(info.tags.title, 'Héllo');
    expect(info.tags.artist, 'Luna Ray');
    expect(info.tags.year, 2023);
    expect(info.tags.trackNumber, 4);
    expect(info.coverCount, 1);
    expect(info.cover!.bytes, jpeg);

    final u = undoWrite(path,
        originalTagBlock: r.originalTagBlock, before: r.before!, coversBefore: r.coversBefore);
    expect(u.ok, isTrue, reason: u.error);
    expect(File(path).readAsBytesSync(), original);
    expect(leftovers(), isEmpty);
  });

  test('frames the app does not know about survive a write', () {
    final comment = frame3('COMM', [0, ...ascii.encode('eng'), 0, ...ascii.encode('liner notes')]);
    final priv = frame3('PRIV', [...ascii.encode('WM/Provider'), 0, 9, 9]);
    final path = put('t.mp3', Uint8List.fromList([
      ...v23([
        frame3('TIT2', [0, ...ascii.encode('Song')]),
        frame3('TCON', [0, ...ascii.encode('Jazz/Blues/Rock')]),
        comment,
        priv,
      ]),
      ...mpegFrames(),
    ]));

    final r = writeTagsAtomic(path, const TagSet(title: 'Song', album: 'New Album', genre: 'Jazz'));
    expect(r.ok, isTrue, reason: r.error);

    final frames = parseId3(File(path).readAsBytesSync())!.frames;
    String body(String id) => latin1.decode(frames.firstWhere((f) => f.id == id).data);
    expect(body('COMM'), contains('liner notes'));
    expect(frames.any((f) => f.id == 'PRIV'), isTrue);
    // "Jazz" is what the file already reads as (the first genre), so the
    // field is unchanged and the full genre string is left alone.
    expect(body('TCON'), contains('Jazz/Blues/Rock'));
    expect(decodeTextFrame(frames.firstWhere((f) => f.id == 'TALB').data), 'New Album');
  });

  test('an existing cover is never replaced', () {
    final apic = frame3('APIC', apicFrameData(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2]), 'image/png'));
    final path = put('c.mp3', Uint8List.fromList([...v23([apic]), ...mpegFrames()]));
    final r = writeTagsAtomic(path, const TagSet(title: 'X'),
        cover: CoverImage(jpeg, 'image/jpeg'));
    expect(r.ok, isTrue, reason: r.error);
    final info = readTrackInfo(path);
    expect(info.coverCount, 1);
    expect(info.cover!.mimeType, 'image/png');
  });

  test('nothing to change leaves the file untouched', () {
    final path = put('same.mp3', Uint8List.fromList([
      ...v23([frame3('TIT2', [0, ...ascii.encode('Same')])]),
      ...mpegFrames(),
    ]));
    final before = File(path).statSync().modified;
    final bytes = File(path).readAsBytesSync();
    final r = writeTagsAtomic(path, const TagSet(title: 'Same'));
    expect(r.ok, isTrue);
    expect(r.unchanged, isTrue);
    expect(File(path).readAsBytesSync(), bytes);
    expect(File(path).statSync().modified, before);
  });

  test('a format it cannot write is refused, not half-done', () {
    final path = put('x.opus', Uint8List.fromList([1, 2, 3]));
    final r = writeTagsAtomic(path, const TagSet(title: 'T'));
    expect(r.ok, isFalse);
    expect(File(path).readAsBytesSync(), [1, 2, 3]);
  });

  test('a missing file is reported', () {
    final r = writeTagsAtomic('${dir.path}/gone.mp3', const TagSet(title: 'T'));
    expect(r.ok, isFalse);
    expect(r.error, contains('gone'));
  });

  test('stale temp files from a killed write are cleaned up, originals kept', () {
    put('a.mp3', mpegFrames(5));
    put('.a.mp3.mp3sorter-tmp.mp3', mpegFrames(5));
    expect(cleanStaleTemps(dir.path), 1);
    expect(File('${dir.path}/a.mp3').existsSync(), isTrue);
  });

  test('reading never throws', () {
    final path = put('junk.mp3', Uint8List.fromList(utf8.encode('this is not audio')));
    final info = readTrackInfo(path);
    expect(info.tags, TagSet.empty);
  });
}
