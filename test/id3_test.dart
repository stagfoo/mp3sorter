import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/id3.dart';

/// A frame as it sits in a file, built by hand.
List<int> frame(String id, List<int> body, {required int major, List<int> flags = const [0, 0]}) {
  final n = body.length;
  final size = major == 4
      ? syncsafeBytes(n)
      : [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
  return [...ascii.encode(id), ...size, ...flags, ...body];
}

List<int> text(String s) => [0x00, ...latin1.encode(s)];

Uint8List tag(int major, List<List<int>> frames, {int padding = 0, int flags = 0}) {
  final body = [for (final f in frames) ...f, ...List.filled(padding, 0)];
  return Uint8List.fromList(
      [...ascii.encode('ID3'), major, 0, flags, ...syncsafeBytes(body.length), ...body]);
}

/// Fake audio: an MPEG frame header and some bytes we can recognise.
final audio = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00, ...List.generate(64, (i) => i)]);

Uint8List file(Uint8List t) => Uint8List.fromList([...t, ...audio]);

String textOf(List<RawFrame> frames, String id) =>
    decodeTextFrame(frames.firstWhere((f) => f.id == id).data);

void main() {
  group('syncsafe', () {
    test('round-trips', () {
      for (final n in [0, 1, 127, 128, 255, 16383, 16384, 0x0fffffff]) {
        final b = Uint8List.fromList(syncsafeBytes(n));
        expect(readSyncsafe(b, 0), n);
        expect(b.every((x) => x < 0x80), isTrue);
      }
    });
    test('refuses what does not fit', () {
      expect(() => syncsafeBytes(0x10000000), throwsArgumentError);
    });
  });

  group('parseId3', () {
    test('no tag is null', () {
      expect(parseId3(audio), isNull);
    });

    test('reads v2.3 frames and where the audio starts', () {
      final t = tag(3, [frame('TIT2', text('Song'), major: 3)], padding: 20);
      final parsed = parseId3(file(t))!;
      expect(parsed.major, 3);
      expect(parsed.frames.single.id, 'TIT2');
      expect(parsed.tagLength, t.length);
    });

    test('reads v2.4 with syncsafe frame sizes over 127 bytes', () {
      final long = 'x' * 300;
      final parsed = parseId3(file(tag(4, [frame('COMM', text(long), major: 4)])))!;
      expect(parsed.frames.single.data.length, 301);
    });

    test('copes with v2.4 tags that used plain sizes (old iTunes)', () {
      final long = 'y' * 200; // 201 bytes: plain 0x000000C9 is not syncsafe
      final bad = tag(4, [
        frame('COMM', text(long), major: 3), // plain size inside a v2.4 tag
        frame('TIT2', text('After'), major: 3),
      ]);
      final parsed = parseId3(file(bad))!;
      expect(parsed.frames.map((f) => f.id), ['COMM', 'TIT2']);
    });

    test('refuses what it does not edit', () {
      expect(() => parseId3(file(tag(2, []))), throwsA(isA<Id3Unsupported>()));
      expect(() => parseId3(file(tag(3, [], flags: 0x80))),
          throwsA(isA<Id3Unsupported>()));
      expect(() => parseId3(file(tag(3, [], flags: 0x40))),
          throwsA(isA<Id3Unsupported>()));
    });

    test('refuses a tag longer than the file', () {
      final t = tag(3, [frame('TIT2', text('S'), major: 3)]);
      expect(() => parseId3(t.sublist(0, t.length - 3)),
          throwsA(isA<Id3Unsupported>()));
    });
  });

  group('editing', () {
    // A tag like the real one that lost data under the library's writer.
    final priv = frame('PRIV', [...ascii.encode('WM/Provider'), 0, 1, 2, 3], major: 3);
    final comm = frame('COMM', [0, ...ascii.encode('eng'), 0, ...ascii.encode('A long comment')], major: 3);
    final original = file(tag(3, [
      frame('TIT2', text('Digging my Potato'), major: 3),
      frame('TPE1', text('The Seatbelts'), major: 3),
      frame('TRCK', text('16/17'), major: 3),
      frame('TCON', text('Jazz/Blues/Rock'), major: 3),
      comm,
      priv,
      frame('APIC', apicFrameData(Uint8List.fromList([1, 2, 3]), 'image/png'), major: 3),
    ], padding: 50));

    test('changes only the edited frame; the rest survive byte for byte', () {
      final out = editMp3Bytes(original, const Id3Edit(album: 'Cowboy Bebop'));
      final before = parseId3(original)!;
      final after = parseId3(out)!;
      for (final f in before.frames) {
        final g = after.frames.firstWhere((x) => x.id == f.id);
        expect(g.data, f.data, reason: '${f.id} changed');
      }
      expect(textOf(after.frames, 'TALB'), 'Cowboy Bebop');
      expect(textOf(after.frames, 'TCON'), 'Jazz/Blues/Rock');
    });

    test('keeps the audio exactly', () {
      final out = editMp3Bytes(original, const Id3Edit(title: 'New'));
      final start = parseId3(out)!.tagLength;
      expect(out.sublist(start), audio);
    });

    test('keeps frame order and replaces in place', () {
      final out = editMp3Bytes(original, const Id3Edit(artist: 'Yoko Kanno'));
      expect(parseId3(out)!.frames.map((f) => f.id).toList(),
          parseId3(original)!.frames.map((f) => f.id).toList());
    });

    test('keeps the total in TRCK', () {
      final out = editMp3Bytes(original, const Id3Edit(trackNumber: 3));
      expect(textOf(parseId3(out)!.frames, 'TRCK'), '3/17');
    });

    test('never replaces an existing cover', () {
      final out = editMp3Bytes(original,
          Id3Edit(cover: Uint8List.fromList([9, 9, 9]), coverMime: 'image/jpeg'));
      final apics = parseId3(out)!.frames.where((f) => f.id == 'APIC').toList();
      expect(apics, hasLength(1));
      expect(apics.single.data.last, 3);
    });

    test('adds a cover when there is none', () {
      final bare = file(tag(3, [frame('TIT2', text('S'), major: 3)]));
      final out = editMp3Bytes(bare,
          Id3Edit(cover: Uint8List.fromList([0xFF, 0xD8, 0xFF]), coverMime: 'image/jpeg'));
      final apic = parseId3(out)!.frames.singleWhere((f) => f.id == 'APIC');
      expect(apic.data.sublist(0, 12), [0, ...ascii.encode('image/jpeg'), 0]);
      expect(apic.data[12], 3); // front cover
    });

    test('year goes to TYER in v2.3 and TDRC in v2.4, and drags TORY along', () {
      final v3 = file(tag(3, [frame('TORY', text('1990'), major: 3)]));
      final f3 = parseId3(editMp3Bytes(v3, const Id3Edit(year: 1998)))!.frames;
      expect(textOf(f3, 'TYER'), '1998');
      expect(textOf(f3, 'TORY'), '1998');
      final v4 = file(tag(4, []));
      expect(textOf(parseId3(editMp3Bytes(v4, const Id3Edit(year: 2001)))!.frames, 'TDRC'), '2001');
    });

    test('a file with no tag gets a fresh v2.4 one in front of the audio', () {
      final out = editMp3Bytes(audio, const Id3Edit(title: 'Hello'));
      final t = parseId3(out)!;
      expect(t.major, 4);
      expect(textOf(t.frames, 'TIT2'), 'Hello');
      expect(out.sublist(t.tagLength), audio);
    });

    test('non-ASCII text: UTF-8 in v2.4, UTF-16 in v2.3', () {
      const name = 'マキシマム ザ ホルモン';
      final v4 = parseId3(editMp3Bytes(file(tag(4, [])), const Id3Edit(artist: name)))!;
      expect(v4.frames.single.data.first, 0x03);
      expect(textOf(v4.frames, 'TPE1'), name);
      final v3 = parseId3(editMp3Bytes(file(tag(3, [])), const Id3Edit(artist: name)))!;
      expect(v3.frames.single.data.first, 0x01);
      expect(textOf(v3.frames, 'TPE1'), name);
    });

    test('an edit that changes a frame also clears its old flags', () {
      final flagged = file(tag(4, [frame('TIT2', text('Old'), major: 4, flags: [0x00, 0x01])]));
      final out = parseId3(editMp3Bytes(flagged, const Id3Edit(title: 'New')))!;
      expect(out.frames.single.flags, [0, 0]);
    });

    test('duplicate frames of an edited id collapse to one', () {
      final dup = file(tag(3, [
        frame('TPE1', text('A'), major: 3),
        frame('TPE1', text('B'), major: 3),
      ]));
      final out = parseId3(editMp3Bytes(dup, const Id3Edit(artist: 'C')))!;
      expect(out.frames.where((f) => f.id == 'TPE1'), hasLength(1));
      expect(textOf(out.frames, 'TPE1'), 'C');
    });
  });

  group('undo blocks', () {
    test('putting the original block back gives the original file', () {
      final original = file(tag(3, [frame('TIT2', text('Song'), major: 3)], padding: 7));
      final block = originalTagBlock(original);
      final edited = editMp3Bytes(original, const Id3Edit(title: 'Other', album: 'X'));
      expect(replaceTagBlock(edited, block), original);
    });

    test('a file that had no tag goes back to having none', () {
      final edited = editMp3Bytes(audio, const Id3Edit(title: 'T'));
      expect(replaceTagBlock(edited, originalTagBlock(audio)), audio);
    });
  });

  group('decodeTextFrame', () {
    test('handles each encoding', () {
      expect(decodeTextFrame(Uint8List.fromList([0, 0x41, 0x42])), 'AB');
      expect(decodeTextFrame(Uint8List.fromList([3, ...utf8.encode('ñ')])), 'ñ');
      expect(decodeTextFrame(Uint8List.fromList([1, 0xFE, 0xFF, 0, 0x41])), 'A');
      expect(decodeTextFrame(Uint8List.fromList([2, 0, 0x42])), 'B');
      expect(decodeTextFrame(Uint8List(0)), '');
    });
  });
}
