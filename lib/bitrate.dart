/// Working out how good an MP3 actually is, from its frame headers.
///
/// This exists because the tag library gets it wrong. `audio_metadata_reader`
/// reported 64 kbps / 22050 Hz for files that are really 128 kbps / 44100 Hz
/// — exactly half of both, which is the signature of misreading the two
/// MPEG version bits and then indexing the MPEG2 bitrate table instead of
/// the MPEG1 one. Checked against `ffprobe` across a real collection, it
/// was wrong on six of seven sampled files. Building a "low quality" flag
/// on that would have marked most of a library as bad.
///
/// So the headers are read here instead. There are only two tables and one
/// version field to get right, and the result is verifiable against
/// `ffprobe` on any file.
///
/// Reading is done through [ByteSource] rather than from a path, so the
/// whole analyser is pure Dart: tests feed it bytes they built themselves,
/// with no file, no device and no tag library involved.
library;

import 'dart:typed_data';

/// Random access to a file's bytes, without this library knowing what a
/// file is.
abstract class ByteSource {
  int get length;

  /// Up to [count] bytes from [offset]. May return fewer at the end of the
  /// source; must never throw for a read that runs past the end.
  Uint8List read(int offset, int count);
}

/// A [ByteSource] over bytes already in memory. What tests use, and what
/// the app uses for small files.
class MemoryByteSource implements ByteSource {
  MemoryByteSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(int offset, int count) {
    if (offset >= bytes.length || offset < 0) return Uint8List(0);
    final end = (offset + count).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }
}

/// MPEG audio version, from the two version bits.
///
/// The field this file exists to get right. `01` is reserved and means the
/// header is not a real frame header — treating it as a version is how a
/// parser ends up confidently reporting nonsense.
enum MpegVersion { mpeg1, mpeg2, mpeg25 }

/// Bitrate in kbps by index, MPEG1 Layer III. Index 0 is "free format"
/// and 15 is invalid; both are rejected rather than guessed at.
const List<int> _bitrateMpeg1 = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
];

/// The same for MPEG2 and MPEG2.5 Layer III — a completely different set
/// of values, which is why picking the wrong table halves the answer.
const List<int> _bitrateMpeg2 = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
];

const List<int> _sampleRateMpeg1 = [44100, 48000, 32000, 0];
const List<int> _sampleRateMpeg2 = [22050, 24000, 16000, 0];
const List<int> _sampleRateMpeg25 = [11025, 12000, 8000, 0];

/// One decoded frame header.
class FrameHeader {
  const FrameHeader({
    required this.version,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channels,
    required this.frameLength,
    required this.samplesPerFrame,
  });

  final MpegVersion version;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;

  /// Total bytes of this frame including the header.
  final int frameLength;

  final int samplesPerFrame;

  Duration get frameDuration => Duration(
      microseconds: (samplesPerFrame * 1000000 / sampleRate).round());
}

/// Decodes a frame header from four bytes, or null if they are not one.
///
/// Every field is validated rather than assumed. A run of 0xFF bytes
/// inside album art will match the sync word by luck, and accepting it
/// would put a garbage bitrate into the average — so a header is only a
/// header if the version, layer, bitrate index and sample-rate index are
/// all legal.
FrameHeader? decodeFrameHeader(Uint8List b, int offset) {
  if (offset + 4 > b.length) return null;
  final b0 = b[offset], b1 = b[offset + 1], b2 = b[offset + 2],
      b3 = b[offset + 3];

  // 11 sync bits.
  if (b0 != 0xFF || (b1 & 0xE0) != 0xE0) return null;

  final versionBits = (b1 >> 3) & 0x03;
  if (versionBits == 1) return null; // reserved
  final version = switch (versionBits) {
    0 => MpegVersion.mpeg25,
    2 => MpegVersion.mpeg2,
    _ => MpegVersion.mpeg1,
  };

  // Layer bits: 01 is Layer III. Layer I and II are legal MPEG but are not
  // what a .mp3 contains, and their frame maths differs — rejected rather
  // than silently mishandled.
  final layerBits = (b1 >> 1) & 0x03;
  if (layerBits != 1) return null;

  final bitrateIndex = (b2 >> 4) & 0x0F;
  if (bitrateIndex == 0 || bitrateIndex == 15) return null;

  final sampleRateIndex = (b2 >> 2) & 0x03;
  if (sampleRateIndex == 3) return null;

  final isMpeg1 = version == MpegVersion.mpeg1;
  final bitrateKbps =
      isMpeg1 ? _bitrateMpeg1[bitrateIndex] : _bitrateMpeg2[bitrateIndex];
  final sampleRate = switch (version) {
    MpegVersion.mpeg1 => _sampleRateMpeg1[sampleRateIndex],
    MpegVersion.mpeg2 => _sampleRateMpeg2[sampleRateIndex],
    MpegVersion.mpeg25 => _sampleRateMpeg25[sampleRateIndex],
  };
  if (bitrateKbps == 0 || sampleRate == 0) return null;

  final padding = (b2 >> 1) & 0x01;
  final channelMode = (b3 >> 6) & 0x03;
  final channels = channelMode == 3 ? 1 : 2;

  // MPEG1 Layer III packs 1152 samples per frame; MPEG2 and 2.5 pack 576.
  // The frame-length coefficient follows from that.
  final samplesPerFrame = isMpeg1 ? 1152 : 576;
  final coefficient = isMpeg1 ? 144 : 72;
  final frameLength = (coefficient * bitrateKbps * 1000) ~/ sampleRate + padding;
  if (frameLength <= 4) return null;

  return FrameHeader(
    version: version,
    bitrateKbps: bitrateKbps,
    sampleRate: sampleRate,
    channels: channels,
    frameLength: frameLength,
    samplesPerFrame: samplesPerFrame,
  );
}

/// Length of the ID3v2 tag at the start of a source, or 0 if there is none.
///
/// The size is a 28-bit "synchsafe" integer — seven bits per byte, top bit
/// always clear, so the length can never contain a false sync word. Read
/// it as a normal big-endian integer and every tag over 2MB comes out
/// wrong, which puts the frame scan into the middle of album art.
int id3v2Length(ByteSource source) {
  final head = source.read(0, 10);
  if (head.length < 10) return 0;
  if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0; // "ID3"

  final size = (head[6] & 0x7F) << 21 |
      (head[7] & 0x7F) << 14 |
      (head[8] & 0x7F) << 7 |
      (head[9] & 0x7F);

  // A footer is present when bit 4 of the flags byte is set, and adds ten
  // more bytes that are not counted in the size field.
  final hasFooter = (head[5] & 0x10) != 0;
  return 10 + size + (hasFooter ? 10 : 0);
}

/// What a scan of one file concluded.
class Mp3Info {
  const Mp3Info({
    required this.bitrateKbps,
    required this.isVbr,
    required this.sampleRate,
    required this.channels,
    required this.version,
    required this.duration,
    required this.framesSampled,
  });

  /// Average bitrate across the file, in kbps. For a CBR file this is the
  /// single bitrate; for VBR it is the mean of the frames sampled.
  final int bitrateKbps;

  final bool isVbr;
  final int sampleRate;
  final int channels;
  final MpegVersion version;

  /// Estimated playing time. Null when it could not be worked out.
  final Duration? duration;

  final int framesSampled;

  bool get isMono => channels == 1;
}

/// Thrown when a file has no usable MPEG Layer III stream.
class NotAnMp3Exception implements Exception {
  const NotAnMp3Exception(this.message);
  final String message;
  @override
  String toString() => 'NotAnMp3Exception: $message';
}

/// How many points across a file to probe when there is no Xing header
/// and the stream turns out to be variable.
///
/// Spread through the file rather than taken from the front: a 4MB track
/// holds ~10,000 frames, reading all of them is wasteful, and reading
/// only the first few hundred reads low, because track intros are quiet
/// and VBR encoders spend fewer bits on them.
const int kProbePoints = 24;

/// What a Xing/Info/VBRI header said about the whole file.
///
/// VBR encoders write one into the first frame precisely because the
/// per-frame bitrate is meaningless as a summary. When it is there it is
/// both cheaper and more accurate than sampling.
class VbrHeader {
  const VbrHeader({required this.frames, required this.bytes});

  /// Total audio frames in the file.
  final int frames;

  /// Total bytes of audio.
  final int bytes;
}

/// Reads a Xing, Info or VBRI header out of the first frame, if present.
///
/// The side-info block between the frame header and the tag is a
/// different length per version and channel mode, which is why the offset
/// is computed rather than constant — looking in the MPEG1-stereo place
/// on a mono MPEG2 file finds nothing and silently falls back to sampling.
VbrHeader? readVbrHeader(Uint8List frame, FrameHeader header) {
  // VBRI sits at a fixed 32 bytes past the header, and only Fraunhofer
  // writes it.
  if (_magicAt(frame, 36, 'VBRI') && 36 + 26 <= frame.length) {
    return VbrHeader(
      frames: _u32(frame, 36 + 14),
      bytes: _u32(frame, 36 + 10),
    );
  }

  final sideInfo = switch ((header.version, header.channels)) {
    (MpegVersion.mpeg1, 1) => 17,
    (MpegVersion.mpeg1, _) => 32,
    (_, 1) => 9,
    (_, _) => 17,
  };
  final at = 4 + sideInfo;
  if (!_magicAt(frame, at, 'Xing') && !_magicAt(frame, at, 'Info')) {
    return null;
  }
  if (at + 8 > frame.length) return null;

  final flags = _u32(frame, at + 4);
  var cursor = at + 8;
  var frames = 0, bytes = 0;
  if (flags & 0x01 != 0) {
    if (cursor + 4 > frame.length) return null;
    frames = _u32(frame, cursor);
    cursor += 4;
  }
  if (flags & 0x02 != 0) {
    if (cursor + 4 > frame.length) return null;
    bytes = _u32(frame, cursor);
    cursor += 4;
  }
  // Both are needed to say anything about the average; a header carrying
  // only a seek table is no use here.
  if (frames <= 0 || bytes <= 0) return null;
  return VbrHeader(frames: frames, bytes: bytes);
}

/// Big-endian 32-bit read.
///
/// A top-level function rather than a closure over the byte list, which
/// is not a style preference: as a capturing closure inlined at six call
/// sites it crashed the Dart JIT outright — the VM dumped core mid
/// optimisation. AOT builds were fine, so a release APK would have
/// worked and every debug run would have died. Caller checks bounds.
int _u32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// Whether four bytes at [at] spell [tag].
bool _magicAt(Uint8List b, int at, String tag) {
  if (at + 4 > b.length) return false;
  for (var i = 0; i < 4; i++) {
    if (b[at + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether the VBR header's magic says the stream is variable.
///
/// LAME writes "Info" rather than "Xing" when it encoded at a constant
/// rate, which is the only reliable in-file statement of which it was.
bool _looksVariable(Uint8List frame, FrameHeader header) {
  final sideInfo = switch ((header.version, header.channels)) {
    (MpegVersion.mpeg1, 1) => 17,
    (MpegVersion.mpeg1, _) => 32,
    (_, 1) => 9,
    (_, _) => 17,
  };
  final at = 4 + sideInfo;
  if (at + 4 > frame.length) return true;
  return !(frame[at] == 0x49 &&
      frame[at + 1] == 0x6E &&
      frame[at + 2] == 0x66 &&
      frame[at + 3] == 0x6F); // "Info"
}

/// How far into the file to keep looking for the first frame.
///
/// Past the ID3 tag there should be a frame immediately. A larger window
/// than this means the file is not really an MP3, and scanning further is
/// how a scan of a corrupt file hangs.
const int kSyncSearchBytes = 128 * 1024;

/// Reads enough of an MP3 to describe its quality.
///
/// Walks consecutive frames from the first real header, which is the only
/// way to tell CBR from VBR: a VBR file's frames carry different bitrate
/// indices, and nothing in the tag says so. A Xing header would give the
/// average more cheaply, but not every VBR encoder writes one, and a file
/// that lies in its Xing header is commoner than one with no frames.
Mp3Info analyseMp3(ByteSource source) {
  final start = id3v2Length(source);

  // Find the first valid frame. Validated by requiring that the *next*
  // header sits exactly where this one says it will — a single header can
  // appear by chance in album art or a tag, two consecutive ones in
  // agreement essentially cannot.
  final window = source.read(start, kSyncSearchBytes);
  var cursor = -1;
  FrameHeader? first;
  for (var i = 0; i + 4 <= window.length; i++) {
    final h = decodeFrameHeader(window, i);
    if (h == null) continue;
    final next = decodeFrameHeader(window, i + h.frameLength);
    if (next == null) continue;
    cursor = i;
    first = h;
    break;
  }
  if (first == null || cursor < 0) {
    throw const NotAnMp3Exception('no MPEG Layer III frame found');
  }

  final firstFrameStart = start + cursor;

  // A Xing/Info/VBRI header describes the whole file exactly, which no
  // amount of sampling can. Checked first because it is both cheaper and
  // better: one read, and a figure that agrees with ffprobe.
  final firstFrameBytes = source.read(firstFrameStart, first.frameLength);
  final vbrHeader = readVbrHeader(firstFrameBytes, first);
  if (vbrHeader != null) {
    final seconds =
        vbrHeader.frames * first.samplesPerFrame / first.sampleRate;
    final kbps = seconds > 0
        ? (vbrHeader.bytes * 8 / seconds / 1000).round()
        : first.bitrateKbps;
    return Mp3Info(
      bitrateKbps: kbps,
      isVbr: _looksVariable(firstFrameBytes, first),
      sampleRate: first.sampleRate,
      channels: first.channels,
      version: first.version,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      framesSampled: vbrHeader.frames,
    );
  }

  // No header, so probe. Always across the whole file, never just the
  // opening: a track whose first thousand frames are a quiet intro at one
  // bitrate looks constant from the front and is not, and averaging only
  // that opening read 127k for files ffprobe put at 150.
  final span = source.length - firstFrameStart;
  final bitrates = <int>[];
  for (var probe = 0; probe < kProbePoints; probe++) {
    final at = firstFrameStart + (span * probe) ~/ kProbePoints;
    final window = source.read(at, 16 * 1024);
    for (var i = 0; i + 4 <= window.length; i++) {
      final h = decodeFrameHeader(window, i);
      if (h == null) continue;
      // Confirmed by its neighbour, so a false sync word inside the audio
      // data cannot contribute a junk bitrate to the average.
      if (decodeFrameHeader(window, i + h.frameLength) == null) continue;
      bitrates.add(h.bitrateKbps);
      break;
    }
  }

  if (bitrates.isEmpty) bitrates.add(first.bitrateKbps);

  final lowest = bitrates.reduce((a, b) => a < b ? a : b);
  final highest = bitrates.reduce((a, b) => a > b ? a : b);
  final isVbr = lowest != highest;

  // The harmonic mean, not the arithmetic one — and this is the subtle
  // part. Probing at even *byte* offsets lands on high-bitrate frames
  // disproportionately often, because those frames occupy more bytes. The
  // arithmetic mean of such a sample is biased upwards: on a file half at
  // 128 and half at 320 it reports 243 where the true average is 224.
  //
  // Under sampling with probability proportional to bitrate, the expected
  // value of 1/bitrate is exactly n/Σbitrate — so the harmonic mean of the
  // samples recovers the per-frame (time-weighted) average, which is what
  // ffprobe reports and what "the bitrate of this file" means.
  final int average;
  if (!isVbr) {
    average = lowest;
  } else {
    var reciprocal = 0.0;
    for (final b in bitrates) {
      reciprocal += 1 / b;
    }
    average = (bitrates.length / reciprocal).round();
  }

  final audioBytes = source.length - start;
  final duration = average > 0
      ? Duration(milliseconds: (audioBytes * 8 / average).round())
      : null;

  return Mp3Info(
    bitrateKbps: average,
    isVbr: isVbr,
    sampleRate: first.sampleRate,
    channels: first.channels,
    version: first.version,
    duration: duration,
    framesSampled: bitrates.length,
  );
}

// ------------------------------------------------------------- quality

/// How good a file is, in the only terms worth acting on.
enum QualityBand {
  /// Noticeably bad on any decent headphones. Worth re-sourcing.
  low,

  /// Fine for casual listening, visibly short of the source.
  acceptable,

  /// What most people would call good.
  good,

  /// Transparent or near enough.
  high,
}

/// Below this, a file is marked low quality. 128 kbps is the traditional
/// line and still the right one: below it, MP3 artefacts are audible on
/// ordinary equipment rather than only on good equipment.
const int kLowQualityKbps = 128;
const int kAcceptableKbps = 192;
const int kGoodKbps = 256;

/// The band a file falls in.
///
/// VBR is judged more kindly by one step, because a VBR encode at a given
/// average sounds better than a CBR encode at the same number — the bits
/// went where they were needed. A V2 encode averaging 190 is genuinely
/// good, and calling it merely "acceptable" next to a flat CBR 192 would
/// be the wrong advice.
QualityBand bandFor(int bitrateKbps, {bool isVbr = false, int? sampleRate}) {
  // A low sample rate caps real quality whatever the bitrate says: 22 kHz
  // has thrown away everything above 11 kHz before encoding started.
  if (sampleRate != null && sampleRate < 32000) return QualityBand.low;

  final effective = isVbr ? (bitrateKbps * 1.15).round() : bitrateKbps;
  if (effective < kLowQualityKbps) return QualityBand.low;
  if (effective < kAcceptableKbps) return QualityBand.acceptable;
  if (effective < kGoodKbps) return QualityBand.good;
  return QualityBand.high;
}

/// A marker earlier versions of this app wrote into the genre field.
///
/// **Nothing writes it any more, and that was the right call.** Bitrate
/// is derived from the file in about two milliseconds, so storing it cost
/// a real metadata field to save a computation that is free — and it
/// overwrote genres the owner had actually set. Quality is now computed
/// at scan time, shown, and filtered on; it is never persisted.
///
/// The constant survives only so the marker can be *taken back* from
/// files that already carry one.
const String kLowQualityTag = 'low quality';

/// Markers this app has ever written, matched case- and space-insensitively.
const Set<String> kManagedTags = {kLowQualityTag};

/// Whether a genre list carries a marker this app put there.
bool hasQualityTag(List<String> genres) =>
    genres.any((g) => kManagedTags.contains(g.trim().toLowerCase()));

/// The genre list with this app's markers removed and nothing added.
///
/// Order is otherwise preserved — the genres are the owner's, and
/// reordering them would show up as a spurious change on every file.
List<String> stripQualityTags(List<String> existing) => [
      for (final g in existing)
        if (!kManagedTags.contains(g.trim().toLowerCase())) g,
    ];
