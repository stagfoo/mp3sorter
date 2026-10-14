/// What the app knows about one file.
///
/// Deliberately a plain value type with no file handle, no tag library
/// and no Flutter: everything downstream — duplicate grouping, rename
/// planning, quality tagging — is a pure function of a list of these, and
/// can be tested by writing the list out by hand.
library;

import 'bitrate.dart';
import 'levenshtein.dart';

/// One audio file as scanned.
class Track {
  const Track({
    required this.path,
    required this.sizeBytes,
    this.artist,
    this.title,
    this.album,
    this.year,
    this.trackNumber,
    this.genres = const [],
    this.bitrateKbps,
    this.isVbr = false,
    this.sampleRate,
    this.duration,
    this.audioFingerprint,
    this.readError,
  });

  final String path;
  final int sizeBytes;

  final String? artist;
  final String? title;
  final String? album;
  final int? year;
  final int? trackNumber;
  final List<String> genres;

  final int? bitrateKbps;
  final bool isVbr;
  final int? sampleRate;
  final Duration? duration;

  /// A cheap identity for the *audio*, ignoring tags.
  ///
  /// Two files that are the same rip with different tags have the same
  /// fingerprint and different sizes, which is the commonest duplicate in
  /// a real collection and the one a size comparison misses entirely.
  final String? audioFingerprint;

  /// Why the file could not be read, when it could not. A track that
  /// failed to parse is kept in the list rather than dropped — silently
  /// skipping files is how a collection quietly loses things.
  final String? readError;

  bool get isReadable => readError == null;

  /// Whether there is enough here to file the track by artist and title.
  bool get hasUsableTags =>
      (artist?.trim().isNotEmpty ?? false) &&
      (title?.trim().isNotEmpty ?? false);

  QualityBand? get band => bitrateKbps == null
      ? null
      : bandFor(bitrateKbps!, isVbr: isVbr, sampleRate: sampleRate);

  bool get isLowQuality => band == QualityBand.low;

  /// The filename with no directory and no extension — the fallback when
  /// tags are missing, and often the only thing a loose file has.
  String get stem {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  Track copyWith({
    String? path,
    String? artist,
    String? title,
    List<String>? genres,
  }) =>
      Track(
        path: path ?? this.path,
        sizeBytes: sizeBytes,
        artist: artist ?? this.artist,
        title: title ?? this.title,
        album: album,
        year: year,
        trackNumber: trackNumber,
        genres: genres ?? this.genres,
        bitrateKbps: bitrateKbps,
        isVbr: isVbr,
        sampleRate: sampleRate,
        duration: duration,
        audioFingerprint: audioFingerprint,
        readError: readError,
      );

  /// For saving a scan to disk.
  ///
  /// Scanning 3,000 files off an SD card takes nearly three minutes, so
  /// being able to reload one is the difference between trying a
  /// different setting and not bothering.
  Map<String, Object?> toJson() => {
        'path': path,
        'size': sizeBytes,
        if (artist != null) 'artist': artist,
        if (title != null) 'title': title,
        if (album != null) 'album': album,
        if (year != null) 'year': year,
        if (trackNumber != null) 'track': trackNumber,
        if (genres.isNotEmpty) 'genres': genres,
        if (bitrateKbps != null) 'kbps': bitrateKbps,
        if (isVbr) 'vbr': true,
        if (sampleRate != null) 'hz': sampleRate,
        if (duration != null) 'ms': duration!.inMilliseconds,
        if (audioFingerprint != null) 'fp': audioFingerprint,
        if (readError != null) 'error': readError,
      };

  static Track? fromJson(Map<String, Object?> j) {
    final path = j['path'];
    // A row without a path describes nothing. Skipped rather than fatal,
    // so one bad line in a saved scan costs that line.
    if (path is! String || path.isEmpty) return null;
    final ms = j['ms'];
    return Track(
      path: path,
      sizeBytes: (j['size'] as num?)?.toInt() ?? 0,
      artist: j['artist'] as String?,
      title: j['title'] as String?,
      album: j['album'] as String?,
      year: (j['year'] as num?)?.toInt(),
      trackNumber: (j['track'] as num?)?.toInt(),
      genres: (j['genres'] as List?)?.cast<String>() ?? const [],
      bitrateKbps: (j['kbps'] as num?)?.toInt(),
      isVbr: j['vbr'] == true,
      sampleRate: (j['hz'] as num?)?.toInt(),
      duration: ms is num ? Duration(milliseconds: ms.toInt()) : null,
      audioFingerprint: j['fp'] as String?,
      readError: j['error'] as String?,
    );
  }

  @override
  String toString() => 'Track($path, $artist - $title, ${bitrateKbps}k)';
}

/// The artist and title to file a track under, with tags preferred and
/// the filename used as a fallback.
///
/// A collection like this is half properly tagged and half files called
/// `1739349830600.mp3`, so a planner that only reads tags leaves half the
/// work undone, and one that only reads filenames throws away good data.
class InferredNames {
  const InferredNames({
    required this.artist,
    required this.title,
    required this.fromTags,
  });

  final String? artist;
  final String? title;

  /// Whether this came from the tags. A filename guess is worth showing
  /// differently, because it is a guess.
  final bool fromTags;

  bool get isComplete =>
      (artist?.isNotEmpty ?? false) && (title?.isNotEmpty ?? false);
}

/// Separators a filename uses between artist and title, commonest first.
final List<RegExp> _artistTitleSplits = [
  RegExp(r'\s+-\s+'), // "Artist - Title"
  RegExp(r'\s+–\s+'), // en dash, which taggers and YouTube both emit
  RegExp(r'_-_'), // "artist_-_title", from a web download
];

/// Works out what a track should be filed as.
///
/// Tags win when they are there. Otherwise the filename is parsed, which
/// works for `artist - title.mp3` and fails honestly for `1739349830600`
/// rather than inventing an artist.
InferredNames inferNames(Track track) {
  final taggedArtist = track.artist?.trim();
  final taggedTitle = track.title?.trim();
  if ((taggedArtist?.isNotEmpty ?? false) &&
      (taggedTitle?.isNotEmpty ?? false)) {
    return InferredNames(
      artist: taggedArtist,
      title: taggedTitle,
      fromTags: true,
    );
  }

  var stem = track.stem;
  // Strip a leading track number before splitting, or "01 - Artist - Title"
  // parses as artist "01".
  stem = stem.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[-._)]\s*'), '').trim();

  for (final sep in _artistTitleSplits) {
    final parts = stem.split(sep);
    if (parts.length >= 2) {
      final artist = _tidy(parts.first);
      final title = _tidy(parts.sublist(1).join(' - '));
      if (artist.isNotEmpty && title.isNotEmpty) {
        return InferredNames(
          // A tagged value still wins over a parsed one for its own field.
          artist: taggedArtist?.isNotEmpty == true ? taggedArtist : artist,
          title: taggedTitle?.isNotEmpty == true ? taggedTitle : title,
          fromTags: false,
        );
      }
    }
  }

  // Nothing to split on. The whole stem is the best guess at a title, and
  // the artist stays unknown rather than being invented.
  final guessTitle = _tidy(stem);
  return InferredNames(
    artist: taggedArtist?.isNotEmpty == true ? taggedArtist : null,
    title: taggedTitle?.isNotEmpty == true
        ? taggedTitle
        : (guessTitle.isEmpty ? null : guessTitle),
    fromTags: false,
  );
}

/// Turns a filename fragment into something readable.
///
/// Underscores become spaces, because `carly_rae_jepsen` is a filename
/// convention and not how anyone writes a name. Repeated whitespace
/// collapses. Case is left alone: "DJ" and "iTunes" would both be ruined
/// by title-casing, and a wrong capital is worse than an inherited one.
String _tidy(String s) => s
    .replaceAll('_', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Characters no filesystem should be asked to hold.
///
/// Covers the union of what Linux, Android's FAT-formatted SD cards and
/// Windows reject — the strictest wins, because a collection that syncs
/// to any of them has to survive all of them.
final RegExp _unsafeForFilename = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Trailing dots and spaces, which Windows silently strips and then
/// cannot find the file it just wrote.
final RegExp _trailingJunk = RegExp(r'[. ]+$');

/// How long one path component may be.
///
/// 255 bytes is the ext4 and FAT limit. 120 leaves room for the extension,
/// a disambiguating suffix, and the parent directory — and a 200-character
/// filename is unreadable anyway.
const int kMaxComponentLength = 120;

/// Makes a string safe to use as one path component.
String safeComponent(String raw) {
  var s = raw.replaceAll(_unsafeForFilename, '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceFirst(_trailingJunk, '');
  if (s.length > kMaxComponentLength) {
    s = s.substring(0, kMaxComponentLength).trim();
    s = s.replaceFirst(_trailingJunk, '');
  }
  // A component that reduced to nothing, or to a name the filesystem
  // treats specially, would otherwise produce a path that cannot be
  // created or that escapes the target directory.
  if (s.isEmpty || s == '.' || s == '..') return '_';
  return s;
}

/// The canonical artist spelling for each variant, built from a scan.
///
/// Returns a map from every spelling seen to the one to standardise on,
/// so a caller can rewrite tags and paths consistently without having to
/// re-run the clustering.
Map<String, String> canonicalArtists(
  Iterable<Track> tracks, {
  double threshold = kSameNameThreshold,
}) {
  final names = <String>[];
  for (final t in tracks) {
    final n = inferNames(t).artist;
    if (n != null && n.isNotEmpty) names.add(n);
  }
  if (names.isEmpty) return const {};

  final out = <String, String>{};
  for (final group in groupSimilarNames(names, threshold: threshold)) {
    // Weighted by how often each spelling actually appears, not by how
    // many distinct spellings there are — a name used forty times one way
    // and twice another is telling you which is intended.
    final occurrences = [
      for (final n in names)
        if (group.contains(n)) n,
    ];
    final canonical = canonicalName(occurrences);
    for (final variant in group) {
      out[variant] = canonical;
    }
  }
  return out;
}
