/// Frame-header parsing and quality banding.
///
/// Built against synthetic frames rather than real files, so every case —
/// MPEG2 at a low sample rate, a VBR file, a false sync word inside album
/// art — can be constructed exactly rather than hunted for in a
/// collection. The real-file check lives in `tool/verify_bitrate.dart`,
/// which compares this parser against ffprobe.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/bitrate.dart';

/// Builds one MPEG Layer III frame header plus its payload of zeroes.
///
/// Writing the four header bytes by hand is the point: it is the only way
/// to test that the version bits select the right bitrate table, which is
/// the bug that made the off-the-shelf library unusable here.
Uint8List frame({
  MpegVersion version = MpegVersion.mpeg1,
  int bitrateIndex = 9, // MPEG1: 128 kbps
  int sampleRateIndex = 0, // MPEG1: 44100 Hz
  int channelMode = 0, // stereo
  int padding = 0,
}) {
  final versionBits = switch (version) {
    MpegVersion.mpeg25 => 0,
    MpegVersion.mpeg2 => 2,
    MpegVersion.mpeg1 => 3,
  };
  final b1 = 0xE0 | (versionBits << 3) | (1 << 1); // sync + version + layer III
  final b2 = (bitrateIndex << 4) | (sampleRateIndex << 2) | (padding << 1);
  final b3 = channelMode << 6;

  final header = [0xFF, b1, b2, b3];
  final decoded = decodeFrameHeader(Uint8List.fromList(header), 0);
  if (decoded == null) return Uint8List.fromList(header);

  final out = Uint8List(decoded.frameLength);
  out.setRange(0, 4, header);
  return out;
}

Uint8List join(List<Uint8List> parts) {
  final total = parts.fold<int>(0, (s, p) => s + p.length);
  final out = Uint8List(total);
  var at = 0;
  for (final p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

/// An ID3v2 tag of [payload] bytes, with a synchsafe size field.
Uint8List id3(int payload, {bool footer = false}) {
  final out = Uint8List(10 + payload + (footer ? 10 : 0));
  out[0] = 0x49; out[1] = 0x44; out[2] = 0x33; // "ID3"
  out[3] = 3;
  out[5] = footer ? 0x10 : 0;
  out[6] = (payload >> 21) & 0x7F;
  out[7] = (payload >> 14) & 0x7F;
  out[8] = (payload >> 7) & 0x7F;
  out[9] = payload & 0x7F;
  return out;
}

Mp3Info analyse(Uint8List bytes) => analyseMp3(MemoryByteSource(bytes));

void main() {
  group('decoding a frame header', () {
    test('MPEG1 Layer III at 128 kbps, 44100 Hz', () {
      final h = decodeFrameHeader(frame(), 0)!;
      expect(h.version, MpegVersion.mpeg1);
      expect(h.bitrateKbps, 128);
      expect(h.sampleRate, 44100);
      expect(h.samplesPerFrame, 1152);
      expect(h.frameLength, 417); // 144 * 128000 / 44100
    });

    test('the version bits pick the right bitrate table', () {
      // The exact bug that made audio_metadata_reader unusable: the same
      // bitrate index means different things per version, and getting the
      // version wrong halves the answer.
      final one = decodeFrameHeader(
          frame(version: MpegVersion.mpeg1, bitrateIndex: 9), 0)!;
      final two = decodeFrameHeader(
          frame(
              version: MpegVersion.mpeg2,
              bitrateIndex: 9,
              sampleRateIndex: 0),
          0)!;
      expect(one.bitrateKbps, 128);
      expect(two.bitrateKbps, 80, reason: 'MPEG2 index 9 is 80, not 128');
      expect(one.sampleRate, 44100);
      expect(two.sampleRate, 22050);
      expect(two.samplesPerFrame, 576);
    });

    test('MPEG2.5 is recognised, not treated as MPEG2', () {
      final h = decodeFrameHeader(
          frame(version: MpegVersion.mpeg25, sampleRateIndex: 0), 0)!;
      expect(h.version, MpegVersion.mpeg25);
      expect(h.sampleRate, 11025);
    });

    test('padding adds exactly one byte', () {
      final a = decodeFrameHeader(frame(padding: 0), 0)!;
      final b = decodeFrameHeader(frame(padding: 1), 0)!;
      expect(b.frameLength, a.frameLength + 1);
    });

    test('mono is detected', () {
      expect(decodeFrameHeader(frame(channelMode: 3), 0)!.channels, 1);
      expect(decodeFrameHeader(frame(channelMode: 0), 0)!.channels, 2);
    });

    group('invalid headers are rejected rather than guessed at', () {
      test('no sync word', () {
        expect(decodeFrameHeader(Uint8List.fromList([0, 0, 0, 0]), 0), isNull);
      });
      test('reserved version', () {
        // Bits 01. Accepting it is how a parser reports confident nonsense.
        final b = Uint8List.fromList([0xFF, 0xEA, 0x90, 0x00]);
        expect(decodeFrameHeader(b, 0), isNull);
      });
      test('layer I or II', () {
        final b = Uint8List.fromList([0xFF, 0xFC, 0x90, 0x00]);
        expect(decodeFrameHeader(b, 0), isNull);
      });
      test('free-format and invalid bitrate indices', () {
        expect(decodeFrameHeader(frame(bitrateIndex: 0), 0), isNull);
        expect(decodeFrameHeader(frame(bitrateIndex: 15), 0), isNull);
      });
      test('reserved sample-rate index', () {
        expect(decodeFrameHeader(frame(sampleRateIndex: 3), 0), isNull);
      });
      test('truncated input', () {
        expect(decodeFrameHeader(Uint8List.fromList([0xFF, 0xFB]), 0), isNull);
      });
    });
  });

  group('ID3v2 length', () {
    test('absent tag is zero', () {
      expect(id3v2Length(MemoryByteSource(frame())), 0);
    });

    test('the size field is read as synchsafe, not plain big-endian', () {
      // 0x7F,0x7F,0x7F,0x7F synchsafe is 268435455; read plainly it is
      // 2139062143. A tag over 2MB is where the two diverge enough to put
      // the frame scan inside the album art.
      final tag = id3(300);
      expect(id3v2Length(MemoryByteSource(tag)), 310);

      final big = id3(1 << 21);
      expect(id3v2Length(MemoryByteSource(big)), 10 + (1 << 21));
    });

    test('a footer adds ten bytes that the size field omits', () {
      expect(id3v2Length(MemoryByteSource(id3(100, footer: true))), 120);
    });

    test('a short file is handled', () {
      expect(id3v2Length(MemoryByteSource(Uint8List(3))), 0);
    });
  });

  group('analysing a whole file', () {
    test('a CBR file reports its single bitrate', () {
      final f = analyse(join([for (var i = 0; i < 20; i++) frame()]));
      expect(f.bitrateKbps, 128);
      expect(f.isVbr, isFalse);
      expect(f.sampleRate, 44100);
      expect(f.framesSampled, greaterThan(0));
    });

    test('frames are found after an ID3v2 tag', () {
      final f = analyse(join([
        id3(2048),
        for (var i = 0; i < 10; i++) frame(),
      ]));
      expect(f.bitrateKbps, 128);
      expect(f.framesSampled, greaterThan(0));
    });

    test('VBR is detected, and the average is not biased upwards', () {
      // Half at 128, half at 320: equal frame counts, so the true
      // time-weighted average is 224. Probing lands on the 320 frames
      // more often because they are 2.5x longer in bytes, and an
      // arithmetic mean of those samples reported 243. The harmonic mean
      // corrects for exactly that.
      final f = analyse(join([
        for (var i = 0; i < 10; i++) frame(bitrateIndex: 9), // 128
        for (var i = 0; i < 10; i++) frame(bitrateIndex: 14), // 320
      ]));
      expect(f.isVbr, isTrue);
      // Twenty frames against twenty-four probes is a coarse sample, so
      // this is an estimator with real error — the point is that it is
      // centred on the truth rather than pulled above it.
      expect(f.bitrateKbps, closeTo(224, 16));
      expect(f.bitrateKbps, lessThan(243),
          reason: 'the arithmetic mean of byte-uniform probes gave 243');
    });

    test('the estimate tightens on a file with frames to spare', () {
      // 1,000 frames of each, so every probe lands somewhere different
      // and the estimator has room to converge.
      final f = analyse(join([
        for (var i = 0; i < 1000; i++) frame(bitrateIndex: 9),
        for (var i = 0; i < 1000; i++) frame(bitrateIndex: 14),
      ]));
      expect(f.isVbr, isTrue);
      expect(f.bitrateKbps, closeTo(224, 10));
    });

    test('a lone false sync word does not become the first frame', () {
      // Two consecutive agreeing headers are required. A single 0xFF 0xFB
      // pair inside album art would otherwise anchor the whole scan in the
      // wrong place.
      final decoy = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00, 1, 2, 3]);
      final f = analyse(join([
        decoy,
        for (var i = 0; i < 6; i++) frame(bitrateIndex: 14),
      ]));
      expect(f.bitrateKbps, 320, reason: 'anchored on the real frames');
    });

    test('a file with no frames is rejected, not reported as zero', () {
      expect(() => analyse(Uint8List(5000)),
          throwsA(isA<NotAnMp3Exception>()));
    });

    test('an empty file is rejected', () {
      expect(() => analyse(Uint8List(0)), throwsA(isA<NotAnMp3Exception>()));
    });

    test('duration is estimated from the audio bytes', () {
      // 100 frames of 128 kbps / 44100 Hz is 417 bytes each.
      final f = analyse(join([for (var i = 0; i < 100; i++) frame()]));
      expect(f.duration!.inMilliseconds, greaterThan(2000));
      expect(f.duration!.inMilliseconds, lessThan(3200));
    });

    test('a constant file stops early instead of walking all of it', () {
      // 600 frames in, but once the opening run shows one bitrate there
      // is nothing left to learn, and across thousands of files the
      // difference is a scan in seconds rather than minutes.
      final f = analyse(join([for (var i = 0; i < 600; i++) frame()]));
      expect(f.isVbr, isFalse);
      expect(f.framesSampled, lessThanOrEqualTo(kProbePoints));
      expect(f.bitrateKbps, 128);
    });

    test('a variable file is probed across its whole length', () {
      // The bug this fixes: averaging only the opening frames read 127k
      // for files ffprobe put at 150k, because intros are quiet and VBR
      // encoders spend fewer bits on them.
      final quietIntro = [for (var i = 0; i < 60; i++) frame(bitrateIndex: 5)];
      final loudBody = [for (var i = 0; i < 400; i++) frame(bitrateIndex: 14)];
      final f = analyse(join([...quietIntro, ...loudBody]));
      expect(f.isVbr, isTrue);
      expect(f.bitrateKbps, greaterThan(100),
          reason: 'must not report only the quiet opening');
    });
  });

  group('quality bands', () {
    test('the usual CBR ladder', () {
      expect(bandFor(64), QualityBand.low);
      expect(bandFor(96), QualityBand.low);
      expect(bandFor(128), QualityBand.acceptable);
      expect(bandFor(192), QualityBand.good);
      expect(bandFor(320), QualityBand.high);
    });

    test('VBR is judged one notch more kindly', () {
      // A V2 encode averaging 190 sounds better than a flat CBR 190,
      // because the bits went where they were needed.
      expect(bandFor(190, isVbr: false), QualityBand.acceptable);
      expect(bandFor(190, isVbr: true), QualityBand.good);
    });

    test('a low sample rate caps quality whatever the bitrate claims', () {
      // 22 kHz threw away everything above 11 kHz before encoding began.
      expect(bandFor(320, sampleRate: 22050), QualityBand.low);
      expect(bandFor(320, sampleRate: 44100), QualityBand.high);
    });

    test('the boundary values land in the higher band', () {
      expect(bandFor(kLowQualityKbps), QualityBand.acceptable);
      expect(bandFor(kLowQualityKbps - 1), QualityBand.low);
    });
  });

  group('the quality tag is only ever removed', () {
    // Earlier versions wrote "low quality" into the genre field. That was
    // wrong: bitrate is derived from the file in milliseconds, so storing
    // it spent a real metadata field to save a free computation — and it
    // overwrote genres the owner had set. Nothing adds one now; these
    // tests pin the taking-back.

    test('a marker this app wrote is recognised', () {
      expect(hasQualityTag([kLowQualityTag]), isTrue);
      expect(hasQualityTag(['Rock']), isFalse);
      expect(hasQualityTag([]), isFalse);
    });

    test('it is matched case- and space-insensitively', () {
      expect(hasQualityTag(['  Low Quality ']), isTrue);
      expect(hasQualityTag(['LOW QUALITY']), isTrue);
    });

    test('stripping removes the marker and nothing else', () {
      expect(stripQualityTags(['Rock', kLowQualityTag, 'Shoegaze']),
          ['Rock', 'Shoegaze']);
    });

    test('the owner\'s own genres keep their order', () {
      // Reordering would show up as a spurious change on every file.
      expect(stripQualityTags(['Zydeco', 'Ambient', 'Black Metal']),
          ['Zydeco', 'Ambient', 'Black Metal']);
    });

    test('a list with no marker is returned unchanged', () {
      expect(stripQualityTags(['Rock']), ['Rock']);
      expect(stripQualityTags([]), isEmpty);
    });

    test('stripping twice is the same as stripping once', () {
      final once = stripQualityTags(['Rock', kLowQualityTag]);
      expect(stripQualityTags(once), once);
    });
  });
}
