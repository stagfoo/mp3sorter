/// Reading and writing tags on real files — atomically, and checked.
///
/// The last app this replaces lost covers and left half-written files on a
/// phone. So every write here follows the same steps:
///
///  1. copy the file to a hidden temporary file *next to it* (same folder,
///     same filesystem, so the final rename is atomic);
///  2. write the tags into the copy, never the original;
///  3. read the copy back and check the tags and covers landed, and that no
///     cover that was there before has gone;
///  4. only then rename the copy over the original.
///
/// A crash, a full disk or a refusal at any step leaves the original file
/// exactly as it was. The functions are synchronous on purpose: the UI runs
/// them in a background isolate (`Isolate.run`), where blocking is free.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
// ParserTag and the per-format metadata classes are public types the package
// does not re-export; its own writer.dart imports them the same way.
// ignore: implementation_imports
import 'package:audio_metadata_reader/src/metadata/base.dart';

import 'id3.dart';
import 'tags.dart';

/// Extensions this app will try to read.
const Set<String> kAudioExtensions = {
  '.mp3',
  '.flac',
  '.m4a',
  '.mp4',
  '.m4b',
  '.aac',
  '.ogg',
  '.opus',
  '.wav',
};

/// Extensions the tag library can write. Ogg/Opus can be read but not
/// written; those cards say so instead of pretending.
const Set<String> kWritableExtensions = {
  '.mp3',
  '.flac',
  '.m4a',
  '.mp4',
  '.m4b',
  '.wav',
};

String extensionOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash + 1) return '';
  return path.substring(dot).toLowerCase();
}

bool isAudioFile(String path) => kAudioExtensions.contains(extensionOf(path));
bool canWrite(String path) => kWritableExtensions.contains(extensionOf(path));

/// An image to embed.
class CoverImage {
  const CoverImage(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// What a file holds right now.
class TrackInfo {
  const TrackInfo({
    required this.path,
    required this.tags,
    required this.coverCount,
    this.cover,
    this.durationSeconds,
    this.readError,
  });

  final String path;
  final TagSet tags;
  final int coverCount;

  /// The front cover (or first picture), when asked for.
  final CoverImage? cover;
  final int? durationSeconds;
  final String? readError;

  bool get hasCover => coverCount > 0;
}

/// Reads one file. Never throws: an unreadable tag comes back as an empty
/// [TagSet] with [TrackInfo.readError] set, so the card can still be shown
/// and the track tagged from its filename.
///
/// Pictures are always read, even when [withCover] is false, because the
/// cover *count* is what the write path checks to make sure no cover is lost
/// — and the library reports zero pictures whenever images are not fetched.
TrackInfo readTrackInfo(String path, {bool withCover = true}) {
  final file = File(path);
  try {
    final m = readMetadata(file, getImage: true);
    CoverImage? cover;
    if (withCover && m.pictures.isNotEmpty) {
      final p = m.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => m.pictures.first,
      );
      cover = CoverImage(p.bytes, p.mimetype);
    }

    var artist = m.artist;
    var albumArtist = m.albumArtist;
    var year = m.year?.year;
    // The library's generic reader fills "artist" from TPE2 (album artist)
    // before TPE1 (the track's artist), so a compilation reads as "Various
    // Artists" on every track. Read the raw frames for MP3 instead.
    if (extensionOf(path) == '.mp3') {
      final raw = readAllMetadata(file, getImage: false);
      if (raw is Mp3Metadata) {
        artist = raw.leadPerformer ?? raw.originalArtist ?? raw.bandOrOrchestra;
        albumArtist = raw.bandOrOrchestra;
        year = raw.year ?? raw.originalReleaseYear;
      }
    }

    return TrackInfo(
      path: path,
      tags: TagSet(
        artist: artist,
        title: m.title,
        album: m.album,
        albumArtist: albumArtist,
        year: year,
        trackNumber: m.trackNumber,
        genre: m.genres.isEmpty ? null : m.genres.first,
      ).normalised(),
      coverCount: m.pictures.length,
      cover: cover,
      durationSeconds: m.duration?.inSeconds,
    );
  } catch (e) {
    return TrackInfo(
      path: path,
      tags: TagSet.empty,
      coverCount: 0,
      readError: '$e',
    );
  }
}

/// What a write did.
class WriteResult {
  const WriteResult.ok({
    required this.before,
    required this.coversBefore,
    this.originalTagBlock,
    this.unchanged = false,
  }) : error = null;
  const WriteResult.failed(this.error, {this.before, this.coversBefore = 0})
      : originalTagBlock = null,
        unchanged = false;

  final String? error;

  /// The tags as they were.
  final TagSet? before;
  final int coversBefore;

  /// For an MP3: the original ID3v2 block, byte for byte (empty if the file
  /// had none). Undo puts exactly this back, so it restores frames this app
  /// never even looked at.
  final Uint8List? originalTagBlock;

  /// True when there was nothing to change, so the file was not touched.
  final bool unchanged;

  bool get ok => error == null;
}

/// Only the fields that would actually change the file.
///
/// Rewriting a field with what it already says is not harmless: a genre of
/// `Jazz/Blues/Rock` reads back as `Jazz`, and writing `Jazz` would lose the
/// other two. So a field the user left as it was is not written at all.
TagSet changedFields(TagSet before, TagSet wanted) {
  final b = before.normalised();
  final w = wanted.normalised();
  T? diff<T>(T? want, T? was) => (want != null && want != was) ? want : null;
  return TagSet(
    artist: diff(w.artist, b.artist),
    title: diff(w.title, b.title),
    album: diff(w.album, b.album),
    albumArtist: diff(w.albumArtist, b.albumArtist),
    year: diff(w.year, b.year),
    trackNumber: diff(w.trackNumber, b.trackNumber),
    genre: diff(w.genre, b.genre),
  );
}

void _applyTags(ParserTag m, TagSet t, {required bool exact}) {
  // In normal writes a blank field means "leave it alone"; in an exact write
  // (undo for non-MP3 files) it means "this was empty, make it empty again".
  void set<T>(T? value, void Function(T?) setter) {
    if (value != null || exact) setter(value);
  }

  set<String>(t.artist, m.setArtist);
  set<String>(t.title, m.setTitle);
  set<String>(t.album, m.setAlbum);
  set<int>(t.trackNumber, m.setTrackNumber);
  if (t.year != null) {
    m.setYear(DateTime(t.year!));
  } else if (exact) {
    m.setYear(null);
  }
  if (t.genre != null) {
    m.setGenres([t.genre!]);
  } else if (exact) {
    m.setGenres(const []);
  }
  if (t.albumArtist != null || exact) {
    switch (m) {
      case VorbisMetadata():
        m.albumArtist = t.albumArtist == null ? [] : [t.albumArtist!];
      case ApeMetadata():
        m.albumArtist = t.albumArtist;
      default:
        // MP4 and RIFF have no album-artist field in this library; the
        // field is shown but not written for those formats.
        break;
    }
  }
}

String _tmpPathFor(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dir = path.substring(0, slash + 1);
  final name = path.substring(slash + 1);
  // The real extension is kept on the end: the read-back check after a write
  // decides how to parse the copy by its extension.
  return '$dir.$name.mp3sorter-tmp${extensionOf(path)}';
}

/// Checks a freshly written copy against what was asked for, and throws if
/// anything is off. Uses the tag *library* to read it back — a different
/// parser from the one that wrote an MP3 — so a mistake in either shows up.
void _verify(
  TrackInfo before,
  TrackInfo after,
  TagSet written, {
  required int expectedCovers,
  required bool exactCovers,
}) {
  if (after.readError != null) {
    throw StateError('the written copy could not be read back');
  }
  for (final (label, wanted, got) in [
    ('title', written.title, after.tags.title),
    ('artist', written.artist, after.tags.artist),
    ('album', written.album, after.tags.album),
    ('year', written.year, after.tags.year),
    ('track', written.trackNumber, after.tags.trackNumber),
  ]) {
    if (wanted != null && wanted != got) {
      throw StateError('$label did not stick (wanted "$wanted", got "$got")');
    }
  }
  final coversWrong = exactCovers
      ? after.coverCount != expectedCovers
      : after.coverCount < expectedCovers;
  if (coversWrong) {
    throw StateError('covers went from ${before.coverCount} to '
        '${after.coverCount}, expected $expectedCovers — refusing to save');
  }
  if (before.durationSeconds != null &&
      after.durationSeconds != null &&
      (before.durationSeconds! - after.durationSeconds!).abs() > 1) {
    throw StateError('the audio length changed — refusing to save');
  }
}

/// Writes [bytes] next to [path], has [check] inspect the copy, then renames
/// it over the original. On any failure the copy is deleted and the original
/// is untouched.
void _commit(String path, Uint8List? bytes, void Function(File tmp) prepare,
    void Function(File tmp) check) {
  final tmp = File(_tmpPathFor(path));
  try {
    if (bytes != null) {
      tmp.writeAsBytesSync(bytes, flush: true);
    } else {
      File(path).copySync(tmp.path);
    }
    prepare(tmp);
    check(tmp);
    tmp.renameSync(path);
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

/// Writes [tags] (and [cover], if given) into the file at [path], atomically.
///
/// * Only fields that differ from what the file already says are written
///   (see [changedFields]); blank fields are left alone.
/// * [cover] is embedded only when the file has none. An existing cover is
///   never replaced or dropped: if the written copy has fewer pictures than
///   the original, the write is refused and the original kept.
/// * MP3s are edited frame by frame (see `id3.dart`), so frames this app does
///   not know about survive. Other formats go through the tag library.
WriteResult writeTagsAtomic(String path, TagSet tags, {CoverImage? cover}) {
  if (!canWrite(path)) {
    return WriteResult.failed(
        "${extensionOf(path)} tags can't be written yet — nothing was changed");
  }
  final src = File(path);
  if (!src.existsSync()) {
    return const WriteResult.failed('the file is gone — moved or deleted?');
  }

  final isMp3 = extensionOf(path) == '.mp3';
  final before = readTrackInfo(path, withCover: false);
  if (before.readError != null && !isMp3) {
    // Writing into a file whose tags could not be parsed risks rewriting a
    // structure the library misunderstood. MP3 is the exception: one that
    // fails to parse usually just has no tag, which the editor handles.
    return WriteResult.failed(
        "this file's tags couldn't be read, so they weren't touched");
  }

  final change = changedFields(before.tags, tags);
  final addCover = cover != null && before.coverCount == 0;
  if (change.isEmpty && !addCover) {
    return WriteResult.ok(
        before: before.tags, coversBefore: before.coverCount, unchanged: true);
  }
  final expectedCovers = addCover ? 1 : before.coverCount;

  try {
    Uint8List? undoBlock;
    var viaId3 = false;
    Uint8List? newBytes;
    if (isMp3) {
      final original = src.readAsBytesSync();
      try {
        undoBlock = originalTagBlock(original);
        newBytes = editMp3Bytes(
          original,
          Id3Edit(
            title: change.title,
            artist: change.artist,
            album: change.album,
            albumArtist: change.albumArtist,
            year: change.year,
            trackNumber: change.trackNumber,
            genre: change.genre,
            cover: addCover ? cover.bytes : null,
            coverMime: addCover ? cover.mimeType : null,
          ),
        );
        viaId3 = true;
      } on Id3Unsupported {
        // An unusual tag (v2.2, unsynchronised…). Fall through to the
        // library, which rebuilds the tag; the undo block still holds the
        // original, so undo is still exact.
        undoBlock = original.sublist(0, _tagLengthLoose(original));
      }
    }

    _commit(
      path,
      newBytes,
      (tmp) {
        if (viaId3) return;
        updateMetadata(tmp, (m) {
          _applyTags(m, change, exact: false);
          if (addCover) {
            m.setPictures(
                [Picture(cover.bytes, cover.mimeType, PictureType.coverFront)]);
          }
        });
      },
      (tmp) => _verify(before, readTrackInfo(tmp.path, withCover: false), change,
          expectedCovers: expectedCovers, exactCovers: false),
    );
    return WriteResult.ok(
      before: before.tags,
      coversBefore: before.coverCount,
      originalTagBlock: undoBlock,
    );
  } catch (e) {
    return WriteResult.failed('$e',
        before: before.tags, coversBefore: before.coverCount);
  }
}

/// The length of an ID3v2 tag from its header alone, without walking frames
/// (for the fallback path, where the frames are what could not be walked).
int _tagLengthLoose(Uint8List b) {
  if (!hasId3v2(b)) return 0;
  final len = 10 + readSyncsafe(b, 6) + ((b[5] & 0x10) != 0 ? 10 : 0);
  return len > b.length ? 0 : len;
}

/// Undoes a write.
///
/// For an MP3 with a saved [originalTagBlock] the original tag goes back byte
/// for byte. Otherwise the [before] tags are written exactly (blanks
/// included), and a cover this app added is removed when [coversBefore] was 0.
WriteResult undoWrite(
  String path, {
  Uint8List? originalTagBlock,
  required TagSet before,
  required int coversBefore,
}) {
  final src = File(path);
  if (!src.existsSync()) {
    return const WriteResult.failed('the file is gone — moved or deleted?');
  }
  final now = readTrackInfo(path, withCover: false);
  try {
    if (originalTagBlock != null) {
      final current = src.readAsBytesSync();
      final restored = replaceTagBlock(current, originalTagBlock);
      _commit(path, restored, (_) {}, (tmp) {
        final after = readTrackInfo(tmp.path, withCover: false);
        _verify(now, after, before.normalised(),
            expectedCovers: coversBefore, exactCovers: true);
      });
    } else {
      _commit(path, null, (tmp) {
        updateMetadata(tmp, (m) {
          _applyTags(m, before.normalised(), exact: true);
          if (coversBefore == 0) m.setPictures(const []);
        });
      }, (tmp) {
        final after = readTrackInfo(tmp.path, withCover: false);
        _verify(now, after, before.normalised(),
            expectedCovers: coversBefore, exactCovers: coversBefore == 0);
      });
    }
    return WriteResult.ok(before: now.tags, coversBefore: now.coverCount);
  } catch (e) {
    return WriteResult.failed('$e');
  }
}

/// Removes temporary files left by a write that was killed mid-way (the
/// phone died, the app was swiped away). Safe: the originals were never
/// touched, so these are only ever stale copies.
int cleanStaleTemps(String dir) {
  var removed = 0;
  try {
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      if (e is File && e.path.contains('.mp3sorter-tmp')) {
        try {
          e.deleteSync();
          removed++;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return removed;
}
