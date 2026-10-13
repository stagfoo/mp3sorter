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

import 'bitrate.dart';
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
    duration: info?.duration,
    audioFingerprint: fingerprint,
    readError: error,
  );
}
