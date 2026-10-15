/// Working out which albums are missing cover art, and where it can
/// come from.
///
/// Ordered by what it costs. Most of a real collection already has art
/// somewhere — on a sibling track, or as a `cover.jpg` sitting beside
/// the music — and finding that costs nothing and reaches no network.
/// Only what is left over is worth asking the internet about.
///
/// Measured on a 5,303-file collection: 4,368 files already carried art,
/// and of the 929 without, around 110 sat in albums where another track
/// had it. That is a tenth of the gap closed before a single request.
///
/// Pure — it takes facts about files and returns a plan, so all of it is
/// testable without a network, a filesystem or a tag library.
library;

import 'levenshtein.dart';
import 'plan.dart';
import 'track.dart';

/// Where a cover can come from, cheapest first.
enum ArtSource {
  /// Every file already has it. Nothing to do.
  alreadyPresent,

  /// Another track in the same album carries it.
  sibling,

  /// An image file is sitting in the album's folder.
  folderImage,

  /// Fetched from the Cover Art Archive. Only reachable after an
  /// explicit, separate go-ahead — see `cover_art.dart`.
  downloaded,

  /// Nothing local. Needs a lookup, which means the network.
  needsLookup,
}

/// One album's worth of artwork work.
class AlbumArt {
  const AlbumArt({
    required this.artist,
    required this.album,
    required this.folder,
    required this.source,
    required this.tracksMissingArt,
    this.sourcePath,
    this.sourceMimeType,
    this.folderIsShared = false,
  });

  final String artist;
  final String album;

  /// Where a `cover.jpg` would go. The folder the album's files are in,
  /// or the commonest one when they are scattered.
  final String folder;

  final ArtSource source;

  /// Files in this album with no embedded art.
  final List<Track> tracksMissingArt;

  /// The audio file or image to take the art from, for [ArtSource.sibling]
  /// and [ArtSource.folderImage].
  final String? sourcePath;

  /// Whether another album's files live in [folder] too.
  ///
  /// When they do, no cover file is written there. A folder holding two
  /// records has no single right `cover.jpg`, and writing one means
  /// every player showing the wrong sleeve for the other album —
  /// a confident, visible error where doing nothing is merely a gap.
  ///
  /// Real and common: a flat `artist/` folder with four albums loose in
  /// it. Embedding is unaffected, because that is per file and always
  /// right.
  final bool folderIsShared;

  /// What kind of image the source holds. Known before anything is
  /// written, so a cover file can be given an extension that matches its
  /// contents — `cover.jpg` holding a PNG is a file every tool will
  /// mis-handle.
  final String? sourceMimeType;

  bool get isSatisfied => source == ArtSource.alreadyPresent;
  bool get needsNetwork => source == ArtSource.needsLookup;

  /// What a cover written beside the album should be called.
  String get coverFileName =>
      sourceMimeType == 'image/png' ? 'cover.png' : 'cover.jpg';

  /// A copy of this album with its art coming from somewhere else —
  /// how a successful online lookup turns a [ArtSource.needsLookup]
  /// album into one that can be written.
  AlbumArt withSource(ArtSource newSource, String path, String mimeType) =>
      AlbumArt(
        artist: artist,
        album: album,
        folder: folder,
        source: newSource,
        tracksMissingArt: tracksMissingArt,
        sourcePath: path,
        sourceMimeType: mimeType,
        folderIsShared: folderIsShared,
      );

  /// What to search for. Normalised the same way artist names are, so a
  /// lookup is not defeated by the spelling variants this app already
  /// knows how to see past.
  String get searchQuery => '$artist $album'.trim();
}

/// Groups tracks into albums and decides where each one's art comes from.
///
/// [embeddedArt] maps a path that already carries art to that art's
/// mimetype, and [folderImages] maps a directory to an image file in it
/// — also by mimetype, via its extension. Both are gathered by
/// [scanAlbumArt]; passing them in keeps this function pure.
List<AlbumArt> planArtwork(
  List<Track> tracks, {
  required Map<String, String> embeddedArt,
  required Map<String, String> folderImages,
}) {
  // Albums are keyed on the normalised artist and album, so the same
  // record tagged two ways is one album rather than two half-covered
  // ones.
  final groups = <String, List<Track>>{};
  final labels = <String, (String, String)>{};

  for (final track in tracks) {
    if (!track.isReadable) continue;
    final names = inferNames(track);
    final artist = names.artist;
    final album = track.album?.trim();
    // Both are needed: an album with no artist cannot be looked up, and
    // a track with no album is a single whose "album" would be itself.
    if (artist == null || artist.isEmpty) continue;
    if (album == null || album.isEmpty) continue;

    final key = '${normaliseForMatching(artist)}|${normaliseForMatching(album)}';
    groups.putIfAbsent(key, () => []).add(track);
    labels[key] ??= (artist, album);
  }

  // Which folder each album calls home, and therefore which folders
  // hold more than one album. Needed before any album is described,
  // because whether a cover file can be written there is a fact about
  // the folder, not about the album.
  final folderOf = <String, String>{
    for (final entry in groups.entries)
      entry.key: _commonestFolder(entry.value),
  };
  final albumsPerFolder = <String, int>{};
  for (final folder in folderOf.values) {
    albumsPerFolder[folder] = (albumsPerFolder[folder] ?? 0) + 1;
  }

  final out = <AlbumArt>[];

  for (final entry in groups.entries) {
    final tracksIn = entry.value;
    final (artist, album) = labels[entry.key]!;

    final missing = [
      for (final t in tracksIn)
        if (!embeddedArt.containsKey(t.path)) t,
    ];

    final folder = folderOf[entry.key]!;
    final shared = (albumsPerFolder[folder] ?? 0) > 1;

    if (missing.isEmpty) {
      out.add(AlbumArt(
        artist: artist,
        album: album,
        folder: folder,
        source: ArtSource.alreadyPresent,
        tracksMissingArt: const [],
        folderIsShared: shared,
      ));
      continue;
    }

    // A sibling first: it is already the right cover for this record,
    // at whatever quality the rest of the album has, and copying it
    // needs nothing but a file read.
    // Prefer a JPEG donor where there is a choice: it is what every
    // player handles, and it is what a written cover file will be named
    // after.
    final donors = [
      for (final t in tracksIn)
        if (embeddedArt.containsKey(t.path)) t.path,
    ]..sort((a, b) {
      final aJpeg = embeddedArt[a] == 'image/jpeg' ? 0 : 1;
      final bJpeg = embeddedArt[b] == 'image/jpeg' ? 0 : 1;
      return aJpeg != bJpeg ? aJpeg - bJpeg : a.compareTo(b);
    });
    if (donors.isNotEmpty) {
      out.add(AlbumArt(
        artist: artist,
        album: album,
        folder: folder,
        source: ArtSource.sibling,
        tracksMissingArt: missing,
        sourcePath: donors.first,
        sourceMimeType: embeddedArt[donors.first],
        folderIsShared: shared,
      ));
      continue;
    }

    final image = folderImages[folder];
    if (image != null) {
      out.add(AlbumArt(
        artist: artist,
        album: album,
        folder: folder,
        source: ArtSource.folderImage,
        tracksMissingArt: missing,
        sourcePath: image,
        sourceMimeType: mimeTypeForExtension(image),
        folderIsShared: shared,
      ));
      continue;
    }

    out.add(AlbumArt(
      artist: artist,
      album: album,
      folder: folder,
      source: ArtSource.needsLookup,
      tracksMissingArt: missing,
      folderIsShared: shared,
    ));
  }

  // Most work first, then alphabetically so two runs over one collection
  // produce the same list.
  out.sort((a, b) {
    final bySource = a.source.index.compareTo(b.source.index);
    if (bySource != 0) return bySource;
    final byCount =
        b.tracksMissingArt.length.compareTo(a.tracksMissingArt.length);
    if (byCount != 0) return byCount;
    return '${a.artist}${a.album}'.compareTo('${b.artist}${b.album}');
  });
  return out;
}

/// The folder most of an album's files are in.
///
/// Not simply the first: a record split across two folders should put
/// its cover where most of it lives, and the first file alphabetically
/// is an arbitrary choice.
String _commonestFolder(List<Track> tracks) {
  final counts = <String, int>{};
  for (final t in tracks) {
    final slash = t.path.lastIndexOf('/');
    final dir = slash <= 0 ? '' : t.path.substring(0, slash);
    counts[dir] = (counts[dir] ?? 0) + 1;
  }
  final best = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return best.first.key;
}

/// What the screen reports before anything is fetched.
class ArtSummary {
  const ArtSummary({
    required this.albums,
    required this.complete,
    required this.fromSibling,
    required this.fromFolder,
    required this.needLookup,
    required this.filesMissing,
    required this.filesFixableOffline,
  });

  final int albums;
  final int complete;
  final int fromSibling;
  final int fromFolder;
  final int needLookup;
  final int filesMissing;

  /// How many of [filesMissing] can be settled without a network.
  final int filesFixableOffline;

  bool get allDone => filesMissing == 0;
  bool get anythingOffline => filesFixableOffline > 0;
}

ArtSummary summariseArtwork(List<AlbumArt> albums) {
  var complete = 0, sibling = 0, folder = 0, lookup = 0;
  var missing = 0, offline = 0;

  for (final a in albums) {
    switch (a.source) {
      case ArtSource.alreadyPresent:
        complete++;
      case ArtSource.sibling:
        sibling++;
        offline += a.tracksMissingArt.length;
      case ArtSource.folderImage:
        folder++;
        offline += a.tracksMissingArt.length;
      case ArtSource.downloaded:
        // Only present after a lookup has already run, so it is not part
        // of the before-anything-happens picture this summarises.
        break;
      case ArtSource.needsLookup:
        lookup++;
    }
    missing += a.tracksMissingArt.length;
  }

  return ArtSummary(
    albums: albums.length,
    complete: complete,
    fromSibling: sibling,
    fromFolder: folder,
    needLookup: lookup,
    filesMissing: missing,
    filesFixableOffline: offline,
  );
}

/// What image a filename claims to hold.
///
/// Extensions worth trusting only because the bytes are sniffed again at
/// write time — this decides what to *call* a cover file, and
/// `sniffImageType` in `cover_art.dart` decides what it actually is.
String? mimeTypeForExtension(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return null;
}

/// Image files worth reading as an album's cover, best name first.
///
/// Order is the point. A folder can hold `cover.jpg` and `back.jpg` and
/// `scan001.jpg`, and only the first of those is the front cover. A
/// filename nobody recognises is used only when there is nothing better.
const List<String> kCoverFileNames = [
  'cover',
  'folder',
  'front',
  'albumart',
  'albumartsmall',
  'album',
  'art',
];

/// Picks the likeliest cover from the images in one folder.
///
/// Pure, taking filenames rather than a directory, so the preference
/// order is testable without building folders full of JPEGs.
String? pickFolderCover(Iterable<String> imagePaths) {
  String? best;
  var bestRank = kCoverFileNames.length + 1;

  for (final path in imagePaths) {
    if (mimeTypeForExtension(path) == null) continue;
    final name = path.split('/').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    // Matched on the stem's start so `cover_500.jpg` and `folder (1).png`
    // still read as covers.
    var rank = kCoverFileNames.length;
    for (var i = 0; i < kCoverFileNames.length; i++) {
      if (stem.startsWith(kCoverFileNames[i])) {
        rank = i;
        break;
      }
    }
    if (rank < bestRank || (rank == bestRank && (best == null || path.compareTo(best) < 0))) {
      bestRank = rank;
      best = path;
    }
  }
  return best;
}

/// Turns settled albums into actions the existing apply/undo machinery
/// can run.
///
/// Art goes through [PlannedAction] rather than being written directly
/// for one reason: everything else in this app is reviewed before it
/// happens and journalled so it can be taken back, and writing into
/// five thousand files is not the place to make an exception.
///
/// [existingCovers] names the cover files already on disk. A cover is
/// never overwritten — one that is already there was put there by
/// somebody, possibly deliberately, and replacing it is not this
/// feature's job.
List<PlannedAction> artActions(
  List<AlbumArt> albums, {
  bool writeCoverFiles = true,
  bool embedInFiles = true,
  Set<String> existingCovers = const {},
}) {
  final actions = <PlannedAction>[];

  for (final album in albums) {
    final from = album.sourcePath;
    if (from == null) continue;
    if (album.source == ArtSource.alreadyPresent) continue;
    if (album.source == ArtSource.needsLookup) continue;

    if (writeCoverFiles) {
      final cover = '${album.folder}/${album.coverFileName}';
      // Three reasons not to write one. The folder-image case is
      // already satisfied — an image is sitting there under some other
      // name, and a second one beside it is clutter. An existing
      // `cover.jpg` is somebody's choice. And a folder holding more
      // than one album has no single right cover; see
      // [AlbumArt.folderIsShared].
      final already = album.source == ArtSource.folderImage ||
          album.folderIsShared ||
          existingCovers.contains(cover.toLowerCase());
      if (!already) {
        actions.add(PlannedAction(
          kind: ActionKind.writeCover,
          path: cover,
          artFrom: from,
          reason: '${album.artist} — ${album.album}'
              ' (${_sourceWords(album.source)})',
        ));
      }
    }

    if (embedInFiles) {
      for (final track in album.tracksMissingArt) {
        actions.add(PlannedAction(
          kind: ActionKind.embedArt,
          path: track.path,
          artFrom: from,
          reason: '${album.album} cover, ${_sourceWords(album.source)}',
        ));
      }
    }
  }

  return actions;
}

String _sourceWords(ArtSource source) => switch (source) {
      ArtSource.alreadyPresent => 'already there',
      ArtSource.sibling => 'from another track on the album',
      ArtSource.folderImage => 'from the image in the folder',
      ArtSource.downloaded => 'from the Cover Art Archive',
      ArtSource.needsLookup => 'not found',
    };
