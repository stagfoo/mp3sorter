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
  });

  final List<Track> tracks;

  /// Files that looked like audio and could not be read. Surfaced rather
  /// than swallowed: a collection quietly losing files is the failure
  /// mode this whole app exists to avoid.
  final List<String> skipped;

  final Duration elapsed;

  int get readable => tracks.where((t) => t.isReadable).length;
}

/// Reads every audio file under [root].
///
/// [onProgress] fires per file so a scan of thousands can show where it
/// is rather than appearing hung.
Future<ScanResult> scanDirectory(
  Directory root, {
  void Function(int done, String path)? onProgress,
  bool Function()? isCancelled,
}) async {
  final sw = Stopwatch()..start();
  final tracks = <Track>[];
  final skipped = <String>[];
  var done = 0;

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
    tracks.add(await readTrack(file));
  }

  sw.stop();
  return ScanResult(tracks: tracks, skipped: skipped, elapsed: sw.elapsed);
}

/// Reads one file into a [Track].
///
/// Never throws. A file that cannot be parsed comes back as a Track with
/// [Track.readError] set, so it appears in the report instead of
/// disappearing from it.
Future<Track> readTrack(File file) async {
  final size = await file.length();

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
}

/// Finds out which files have art and which folders have an image.
///
/// Separate from [scanDirectory] and run on demand, because it is the
/// expensive one: finding out whether a file has a cover means reading
/// the cover, and `getImage: false` is exactly why the main scan of five
/// thousand files is quick. This pass reads every embedded image to
/// decide whether there is one, so it is behind its own button with its
/// own progress.
Future<ArtScan> scanAlbumArt(
  List<Track> tracks, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final sw = Stopwatch()..start();
  final embedded = <String, String>{};
  final unreadable = <String>[];
  final folders = <String>{};

  for (var i = 0; i < tracks.length; i++) {
    if (isCancelled?.call() ?? false) break;
    final track = tracks[i];
    onProgress?.call(i + 1, tracks.length);

    final slash = track.path.lastIndexOf('/');
    folders.add(slash <= 0 ? '' : track.path.substring(0, slash));

    if (!track.isReadable) continue;
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
  );
}
