/// A frame-preserving ID3v2 editor.
///
/// Why this exists: the tag library's MP3 writer rebuilds the tag from the
/// fields it understands, so everything else is silently dropped — tested on
/// a real file from the collection, a write lost its COMM comment, the
/// iTunes normalisation data and seven PRIV frames, and cut a genre of
/// `Jazz/Blues/Rock` down to `Jazz`. A tagger that damages tags while fixing
/// them is how a library ends up worse than it started.
///
/// So for MP3 this edits the tag at the frame level: the frames being changed
/// are replaced, and every other frame is copied through byte for byte,
/// flags and all. Pure functions on bytes — no file access — so every case
/// is tested with tags built by hand.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One frame, kept raw: its four-character id, its two flag bytes, and its
/// body exactly as it was in the file.
class RawFrame {
  const RawFrame(this.id, this.flags, this.data);
  final String id;
  final Uint8List flags;
  final Uint8List data;
}

/// A parsed ID3v2 tag at the start of a file.
class Id3Tag {
  const Id3Tag({
    required this.major,
    required this.frames,
    required this.tagLength,
  });

  /// 3 or 4. Version 2.2 (three-character ids) is not edited here.
  final int major;
  final List<RawFrame> frames;

  /// Bytes from the start of the file to the first byte after the tag,
  /// padding included — where the audio starts.
  final int tagLength;
}

/// Why a tag could not be edited at the frame level. The caller falls back
/// to a different writer rather than guessing.
class Id3Unsupported implements Exception {
  Id3Unsupported(this.reason);
  final String reason;
  @override
  String toString() => 'Id3Unsupported: $reason';
}

int readSyncsafe(Uint8List b, int o) =>
    (b[o] & 0x7f) << 21 |
    (b[o + 1] & 0x7f) << 14 |
    (b[o + 2] & 0x7f) << 7 |
    (b[o + 3] & 0x7f);

int _readPlain(Uint8List b, int o) =>
    b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

List<int> syncsafeBytes(int n) {
  if (n < 0 || n > 0x0fffffff) {
    throw ArgumentError('too large for a syncsafe integer: $n');
  }
  return [(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f];
}

List<int> _plainBytes(int n) =>
    [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

bool hasId3v2(Uint8List b) =>
    b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33;

bool _validId(Uint8List b, int o) {
  for (var i = 0; i < 4; i++) {
    final c = b[o + i];
    final ok = (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39);
    if (!ok) return false;
  }
  return true;
}

/// Walks the frames with one size encoding; null if the walk goes wrong.
List<RawFrame>? _walk(Uint8List b, int start, int end, {required bool syncsafe}) {
  final frames = <RawFrame>[];
  var o = start;
  while (o + 10 <= end) {
    if (b[o] == 0) break; // padding
    if (!_validId(b, o)) return null;
    final id = ascii.decode(b.sublist(o, o + 4));
    final size = syncsafe ? readSyncsafe(b, o + 4) : _readPlain(b, o + 4);
    final bodyStart = o + 10;
    if (size < 0 || bodyStart + size > end) return null;
    frames.add(RawFrame(
      id,
      Uint8List.fromList(b.sublist(o + 8, o + 10)),
      Uint8List.fromList(b.sublist(bodyStart, bodyStart + size)),
    ));
    o = bodyStart + size;
  }
  return frames;
}

/// Parses the ID3v2 tag at the start of [b]. Returns null when there is none.
///
/// Throws [Id3Unsupported] for the shapes this does not edit: v2.2,
/// whole-tag unsynchronisation, an extended header, or a footer. All rare,
/// and all better left to a writer that rebuilds than half-handled here.
Id3Tag? parseId3(Uint8List b) {
  if (!hasId3v2(b)) return null;
  final major = b[3];
  if (major != 3 && major != 4) {
    throw Id3Unsupported('ID3v2.$major');
  }
  final flags = b[5];
  if (flags & 0x80 != 0) throw Id3Unsupported('unsynchronised tag');
  if (flags & 0x40 != 0) throw Id3Unsupported('extended header');
  if (flags & 0x10 != 0) throw Id3Unsupported('tag footer');

  final size = readSyncsafe(b, 6);
  final end = 10 + size;
  if (end > b.length) throw Id3Unsupported('tag runs past the end of the file');

  // v2.4 sizes are syncsafe and v2.3 sizes are plain — except that some
  // well-known writers (older iTunes among them) wrote plain sizes into
  // v2.4 tags. Try the correct encoding first and the other if the walk
  // falls apart.
  var frames = _walk(b, 10, end, syncsafe: major == 4) ??
      _walk(b, 10, end, syncsafe: major != 4);
  if (frames == null) throw Id3Unsupported('frames could not be walked');
  return Id3Tag(major: major, frames: frames, tagLength: end);
}

/// Serialises a tag: header, frames (each with its original flags), then
/// [padding] zero bytes so the next edit can usually be done in place by
/// other tools.
Uint8List buildId3(int major, List<RawFrame> frames, {int padding = 1024}) {
  final body = BytesBuilder(copy: false);
  for (final f in frames) {
    body.add(ascii.encode(f.id));
    body.add(major == 4 ? syncsafeBytes(f.data.length) : _plainBytes(f.data.length));
    body.add(f.flags);
    body.add(f.data);
  }
  body.add(Uint8List(padding));
  final bytes = body.takeBytes();
  final out = BytesBuilder(copy: false)
    ..add(ascii.encode('ID3'))
    ..add([major, 0, 0])
    ..add(syncsafeBytes(bytes.length))
    ..add(bytes);
  return out.takeBytes();
}

/// A text frame body in the best encoding the version allows: UTF-8 for
/// v2.4, UTF-16 with a BOM for v2.3 (which has no UTF-8). Plain ASCII is
/// written as Latin-1 in both, for the oldest players.
Uint8List textFrameData(String text, int major) {
  final isAscii = text.codeUnits.every((c) => c < 0x80);
  if (isAscii) return Uint8List.fromList([0x00, ...latin1.encode(text)]);
  if (major == 4) return Uint8List.fromList([0x03, ...utf8.encode(text)]);
  final units = <int>[0x01, 0xff, 0xfe]; // UTF-16, little-endian BOM
  for (final u in text.codeUnits) {
    units..add(u & 0xff)..add(u >> 8);
  }
  return Uint8List.fromList(units);
}

/// An APIC (attached picture) body for a front cover.
Uint8List apicFrameData(Uint8List image, String mimeType) =>
    Uint8List.fromList([
      0x00, // Latin-1 description
      ...latin1.encode(mimeType),
      0x00,
      0x03, // front cover
      0x00, // empty description
      ...image,
    ]);

/// Decodes a text frame body (for reading TRCK's "n/total" and tests).
String decodeTextFrame(Uint8List data) {
  if (data.isEmpty) return '';
  final enc = data[0];
  final body = data.sublist(1);
  String s;
  switch (enc) {
    case 0x00:
      s = latin1.decode(body);
    case 0x03:
      s = utf8.decode(body, allowMalformed: true);
    case 0x01:
    case 0x02:
      var bigEndian = enc == 0x02;
      var start = 0;
      if (body.length >= 2 && body[0] == 0xff && body[1] == 0xfe) {
        bigEndian = false;
        start = 2;
      } else if (body.length >= 2 && body[0] == 0xfe && body[1] == 0xff) {
        bigEndian = true;
        start = 2;
      }
      final units = <int>[];
      for (var i = start; i + 1 < body.length; i += 2) {
        units.add(bigEndian ? (body[i] << 8 | body[i + 1]) : (body[i + 1] << 8 | body[i]));
      }
      s = String.fromCharCodes(units);
    default:
      s = latin1.decode(body);
  }
  return s.replaceAll('\u0000', '').trim();
}

/// What to change. A null field is left alone; [remove] lists frame ids to
/// drop outright.
class Id3Edit {
  const Id3Edit({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.trackNumber,
    this.genre,
    this.cover,
    this.coverMime,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final int? year;
  final int? trackNumber;
  final String? genre;

  /// A cover to add. Only added when the tag has no APIC frame at all —
  /// replacing someone's cover is never a side effect.
  final Uint8List? cover;
  final String? coverMime;

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      albumArtist == null &&
      year == null &&
      trackNumber == null &&
      genre == null &&
      cover == null;
}

final Uint8List _noFlags = Uint8List(2);

/// Applies [edit] to [frames], returning the new frame list.
///
/// Edited frames keep their position (a player that cares about order sees
/// the same order) and are written with cleared flags, since a flag like
/// "compressed" described the old body, not the new one. New frames go at
/// the end.
List<RawFrame> applyId3Edit(List<RawFrame> frames, Id3Edit edit, int major) {
  final out = List<RawFrame>.of(frames);

  void setText(String id, String? value) {
    if (value == null) return;
    final frame = RawFrame(id, _noFlags, textFrameData(value, major));
    final i = out.indexWhere((f) => f.id == id);
    if (i >= 0) {
      out[i] = frame;
      out.removeWhere((f) => f.id == id && !identical(f, frame));
    } else {
      out.add(frame);
    }
  }

  setText('TIT2', edit.title);
  setText('TPE1', edit.artist);
  setText('TALB', edit.album);
  setText('TPE2', edit.albumArtist);
  setText('TCON', edit.genre);

  if (edit.year != null) {
    // v2.4 has TDRC; v2.3 has TYER. A stale TORY/TDOR (original release
    // year) is preferred by some readers, so it follows the new year rather
    // than being left to contradict it.
    setText(major == 4 ? 'TDRC' : 'TYER', '${edit.year}');
    if (out.any((f) => f.id == 'TORY')) setText('TORY', '${edit.year}');
    if (out.any((f) => f.id == 'TDOR')) setText('TDOR', '${edit.year}');
  }

  if (edit.trackNumber != null) {
    // Keep the "/total" half of an existing "3/12".
    final existing = out.where((f) => f.id == 'TRCK').firstOrNull;
    var total = '';
    if (existing != null) {
      final old = decodeTextFrame(existing.data);
      final slash = old.indexOf('/');
      if (slash >= 0) total = old.substring(slash);
    }
    setText('TRCK', '${edit.trackNumber}$total');
  }

  if (edit.cover != null && !out.any((f) => f.id == 'APIC')) {
    out.add(RawFrame(
      'APIC',
      _noFlags,
      apicFrameData(edit.cover!, edit.coverMime ?? 'image/jpeg'),
    ));
  }
  return out;
}

/// Rewrites the tag at the front of [file] with [edit] applied, returning the
/// whole new file. A file with no tag gets a fresh v2.4 one.
Uint8List editMp3Bytes(Uint8List file, Id3Edit edit) {
  final tag = parseId3(file);
  final major = tag?.major ?? 4;
  final frames = applyId3Edit(tag?.frames ?? const [], edit, major);
  final head = buildId3(major, frames);
  final audioStart = tag?.tagLength ?? 0;
  final out = BytesBuilder(copy: false)
    ..add(head)
    ..add(Uint8List.sublistView(file, audioStart));
  return out.takeBytes();
}

/// The original tag block of [file], byte for byte — what undo puts back.
Uint8List originalTagBlock(Uint8List file) {
  final tag = parseId3(file);
  if (tag == null) return Uint8List(0);
  return Uint8List.fromList(file.sublist(0, tag.tagLength));
}

/// Swaps the tag at the front of [file] for [block] (which may be empty, for
/// a file that had no tag). The audio after the tag is untouched.
Uint8List replaceTagBlock(Uint8List file, Uint8List block) {
  final tag = parseId3(file);
  final audioStart = tag?.tagLength ?? 0;
  final out = BytesBuilder(copy: false)
    ..add(block)
    ..add(Uint8List.sublistView(file, audioStart));
  return out.takeBytes();
}
