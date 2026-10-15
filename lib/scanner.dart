/// Walking a directory and reading what is in it.
///
/// The one part of the pipeline that must touch the filesystem, kept to
/// one file so everything downstream stays pure. Two decisions here carry
/// most of the weight:
///
///  * **Bitrate comes from `bitrate.dart`, not the tag library.** The tag
///    library halves it on most files — see that file's header. Tags come
///    from the library, audio facts come from the frame parser.
///  * **The fingerprint samples rather than hashes everything.** Hashing
///    25 GB to find duplicates costs minutes of disk; sampling the ends of
///    the audio stream costs nothing and is just as decisive.
library;

import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';

import 'artwork.dart';
import 'bitrate.dart';
import 'cover_art.dart';
import 'file_source.dart';
import 'track.dart';
import 'track_index.dart';

/// Extensions worth opening. Anything else in the folder is ignored
/// rather than reported as an error — a collection has cover art and
/// playlists in it, and calling those failures is noise.
const Set<String> kAudioExtensions = {'.mp3'};

/// How much of the audio stream goes into the fingerprint, from each end.
///
/// 64 KB is about a second and a half at 320 kbps. Two different songs
/// agreeing on their first *and* last second and a half, and on their
/// exact audio length, does not happen; two copies of one song always do.
const int kFingerprintSampleBytes = 64 * 1024;

/// Identity for the audio, ignoring tags.
///
/// Deliberately computed over the audio frames only, skipping the ID3
/// tag. That is what makes the commonest real duplicate — one rip,
/// tagged twice, so the files differ in size — detectable at all.
String? fingerprintAudio(ByteSource source) {
  final start = id3v2Length(source);
  final audioLength = source.length - start;
  if (audioLength <= 0) return null;

  final head = source.read(start, kFingerprintSampleBytes);
  final tailAt = audioLength > kFingerprintSampleBytes * 2
      ? source.length - kFingerprintSampleBytes
      : start + (audioLength ~/ 2);
  final tail = source.read(tailAt, kFingerprintSampleBytes);

  final digest = sha1.convert([
    ...utf8.encode('$audioLength:'),
    ...head,
    ...tail,
  ]);
  return digest.toString();
}

/// What a scan found.
class ScanResult {
  const ScanResult({
    required this.tracks,
    required this.skipped,
    required this.elapsed,
    this.reuse = const ReuseStats(reused: 0, read: 0, vanished: 0),
  });

  final List<Track> tracks;

  /// Files that looked like audio and could not be read. Surfaced rather
  /// than swallowed: a collection quietly losing files is the failure
  /// mode this whole app exists to avoid.
  final List<String> skipped;

  final Duration elapsed;

  /// How much came from the index rather than from the disk.
  final ReuseStats reuse;

  int get readable => tracks.where((t) => t.isReadable).length;
}

/// Reads every audio file under [root].
///
/// [onProgress] fires per file so a scan of thousands can show where it
/// is rather than appearing hung.
///
/// [reuse] is an index from a previous scan. Any file whose size and
/// modification time match what the index recorded is taken from the
/// index instead of being opened — which is the difference between a
/// rescan costing 22 seconds and costing a fifth of one, because
/// reading a file costs 3.7ms and `stat`ing it costs about ten
/// microseconds. An index for a different root is ignored.
Future<ScanResult> scanDirectory(
  Directory root, {
  void Function(int done, String path)? onProgress,
  bool Function()? isCancelled,
  TrackIndex? reuse,
}) async {
  final sw = Stopwatch()..start();
  final tracks = <Track>[];
  final skipped = <String>[];
  var done = 0;

  // Only an index of this very folder. A collection remounted at a
  // different path is a different set of paths, and matching on size and
  // time across them would be matching on nothing.
  final cached = (reuse != null && _samePath(reuse.rootPath, root.path))
      ? reuse.byPath
      : const <String, Track>{};
  final seen = <String>{};
  var reused = 0, readFromDisk = 0;

  final entries = <File>[];
  try {
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final lower = e.path.toLowerCase();
      if (!kAudioExtensions.any(lower.endsWith)) continue;
      entries.add(e);
    }
  } on FileSystemException catch (e) {
    // An unreadable subdirectory should cost that subdirectory, not the
    // scan — on Android this is routine for folders another app owns.
    skipped.add('${root.path}: $e');
  }

  entries.sort((a, b) => a.path.compareTo(b.path));

  for (final file in entries) {
    if (isCancelled?.call() ?? false) break;
    done++;
    onProgress?.call(done, file.path);
    seen.add(file.path);

    // One `stat`, then usually nothing else at all.
    final known = cached[file.path];
    if (known != null) {
      FileStat? stat;
      try {
        stat = file.statSync();
      } catch (_) {
        // Unreadable right now. Falls through to a real read, which
        // will record the failure properly.
      }
      if (stat != null &&
          known.matchesStamp(
              stat.size, stat.modified.millisecondsSinceEpoch)) {
        tracks.add(known);
        reused++;
        continue;
      }
    }

    readFromDisk++;
    tracks.add(await readTrack(file));
  }

  sw.stop();
  return ScanResult(
    tracks: tracks,
    skipped: skipped,
    elapsed: sw.elapsed,
    reuse: ReuseStats(
      reused: reused,
      read: readFromDisk,
      // Files the index knew that the walk did not find. Counted rather
      // than acted on: they are simply absent from the new scan, which
      // is the correct outcome, and the number is worth seeing because a
      // card half-mounted reports thousands of them.
      // Through a set, not a nested scan: `entries.any` inside a loop
      // over 5,303 cached paths is 28 million string comparisons for a
      // number that is only shown on screen.
      vanished: cached.isEmpty
          ? 0
          : cached.keys.where((p) => !seen.contains(p)).length,
    ),
  );
}

/// Compares two folder paths, ignoring a trailing slash.
bool _samePath(String a, String b) {
  String tidy(String p) {
    var out = p.trim();
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  return tidy(a) == tidy(b);
}

/// Reads one file into a [Track].
///
/// Never throws. A file that cannot be parsed comes back as a Track with
/// [Track.readError] set, so it appears in the report instead of
/// disappearing from it.
Future<Track> readTrack(File file) async {
  // One `stat` for both, rather than a length call and a time call.
  FileStat? stat;
  try {
    stat = file.statSync();
  } catch (_) {
    // Left null; the size falls back to zero and the stamp to unknown,
    // which means the next scan re-reads this file rather than trusting
    // a stamp that was never read.
  }
  final size = stat?.size ?? 0;
  final modifiedMs = stat?.modified.millisecondsSinceEpoch ?? 0;

  FileByteSource? source;
  Mp3Info? info;
  String? fingerprint;
  String? error;

  try {
    source = FileByteSource(file);
    info = analyseMp3(source);
    fingerprint = fingerprintAudio(source);
  } catch (e) {
    error = '$e';
  } finally {
    source?.close();
  }

  // Tags are read separately, and a tag failure is not an audio failure:
  // a perfectly good MP3 with a corrupt ID3 block should still be filed
  // by its filename rather than written off.
  String? artist, title, album;
  int? year, trackNumber;
  var genres = const <String>[];
  try {
    final m = readMetadata(file, getImage: false);
    artist = m.artist;
    title = m.title;
    album = m.album;
    year = m.year?.year;
    trackNumber = m.trackNumber;
    genres = List<String>.from(m.genres);
  } catch (_) {
    // Left null. inferNames falls back to the filename.
  }

  return Track(
    path: file.path,
    sizeBytes: size,
    modifiedMs: modifiedMs,
    artist: artist,
    title: title,
    album: album,
    year: year,
    trackNumber: trackNumber,
    genres: genres,
    bitrateKbps: info?.bitrateKbps,
    isVbr: info?.isVbr ?? false,
    sampleRate: info?.sampleRate,
    channels: info?.channels,
    duration: info?.duration,
    audioFingerprint: fingerprint,
    readError: error,
  );
}

/// Image extensions worth opening as a cover.
const Set<String> kImageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

/// What an art scan found.
class ArtScan {
  const ArtScan({
    required this.embeddedArt,
    required this.folderImages,
    required this.existingCovers,
    required this.unreadable,
    required this.elapsed,
    this.checked = const {},
    this.reusedCount = 0,
  });

  /// Paths that already carry a cover, mapped to its mimetype.
  final Map<String, String> embeddedArt;

  /// Folder → the likeliest cover image in it.
  final Map<String, String> folderImages;

  /// Every image file already sitting where this app would write one.
  /// Lower-cased, because a cover is not written twice just because the
  /// card spells it `Cover.JPG`.
  final Set<String> existingCovers;

  final List<String> unreadable;
  final Duration elapsed;

  /// Paths the pass actually looked at, whether or not art was found.
  /// Carried into the index so the next pass can skip them.
  final Set<String> checked;

  /// How many covers were taken from the index rather than read.
  final int reusedCount;
}

/// Finds out which files have art and which folders have an image.
///
/// Separate from [scanDirectory] and run on demand, because it is the
/// expensive one: finding out whether a file has a cover means reading
/// the cover, and `getImage: false` is exactly why the main scan of five
/// thousand files is quick. This pass reads every embedded image to
/// decide whether there is one, so it is behind its own button with its
/// own progress.
///
/// [reuse] does for this pass what it does for [scanDirectory]: a file
/// the index has already checked, and whose stamp still matches, is not
/// opened again. A second art pass over an untouched collection then
/// reads nothing at all.
Future<ArtScan> scanAlbumArt(
  List<Track> tracks, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
  TrackIndex? reuse,
}) async {
  final sw = Stopwatch()..start();
  final embedded = <String, String>{};
  final unreadable = <String>[];
  final folders = <String>{};
  final checked = <String>{};
  var reusedCount = 0;

  // The index's own view of each track, to compare stamps against. A
  // file whose stamp has moved on has been rewritten since the art pass
  // last looked, so whatever it said then is no longer a fact.
  final previous = reuse?.byPath ?? const <String, Track>{};
  final previouslyChecked = reuse?.artChecked ?? const <String>{};
  final previousArt = reuse?.embeddedArt ?? const <String, String>{};

  for (var i = 0; i < tracks.length; i++) {
    if (isCancelled?.call() ?? false) break;
    final track = tracks[i];
    onProgress?.call(i + 1, tracks.length);

    final slash = track.path.lastIndexOf('/');
    folders.add(slash <= 0 ? '' : track.path.substring(0, slash));

    if (!track.isReadable) continue;

    // Checked before, and the file has not been written since. The
    // stamp comparison is the whole safeguard: without it, a file this
    // app had just embedded a cover into would still be reported as
    // having none.
    final before = previous[track.path];
    if (previouslyChecked.contains(track.path) &&
        before != null &&
        track.modifiedMs != 0 &&
        before.modifiedMs == track.modifiedMs &&
        before.sizeBytes == track.sizeBytes) {
      checked.add(track.path);
      final mime = previousArt[track.path];
      if (mime != null) embedded[track.path] = mime;
      reusedCount++;
      continue;
    }

    checked.add(track.path);
    try {
      final meta = readMetadata(File(track.path), getImage: true);
      if (meta.pictures.isEmpty) continue;
      final picture = meta.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => meta.pictures.first,
      );
      // Sniffed rather than taken from the tag's own claim: a tag saying
      // `image/jpeg` over PNG bytes is common enough, and the claim is
      // what a written `cover.jpg` would be named after.
      final type = sniffImageType(picture.bytes);
      // A picture whose bytes are not a recognisable image counts as no
      // art — it cannot be copied to a sibling, and treating it as art
      // would leave the album looking done while every player shows
      // nothing.
      if (type == null) continue;
      embedded[track.path] = type;
    } catch (e) {
      unreadable.add('${track.path}: $e');
    }
  }

  // One listing per folder rather than one per file: an album of twenty
  // tracks is one directory read, not twenty.
  final folderImages = <String, String>{};
  final existingCovers = <String>{};
  for (final folder in folders) {
    if (isCancelled?.call() ?? false) break;
    try {
      final images = <String>[];
      for (final e in Directory(folder).listSync(followLinks: false)) {
        if (e is! File) continue;
        final lower = e.path.toLowerCase();
        if (!kImageExtensions.any(lower.endsWith)) continue;
        images.add(e.path);
        existingCovers.add(lower);
      }
      final pick = pickFolderCover(images);
      if (pick != null) folderImages[folder] = pick;
    } on FileSystemException catch (e) {
      unreadable.add('$folder: $e');
    }
  }

  sw.stop();
  return ArtScan(
    embeddedArt: embedded,
    folderImages: folderImages,
    existingCovers: existingCovers,
    unreadable: unreadable,
    elapsed: sw.elapsed,
    checked: checked,
    reusedCount: reusedCount,
  );
}
