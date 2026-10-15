/// The collection, kept as data between runs.
///
/// ## Why this exists
///
/// Reading one file costs about 3.7ms, nearly all of it the 128 KB the
/// fingerprint samples. `stat`ing all 5,303 costs 56ms *in total*. So a
/// rescan that reads only what changed is not a small improvement over
/// one that reads everything — it is three orders of magnitude on the
/// part that dominates, and on a tablet reading a removable card it is
/// the difference between minutes and a moment.
///
/// ## The second thing it fixes
///
/// Every change this app makes is already described exactly, in the
/// journal, before it happens. So after a run the index can be *edited*
/// to match — a move rewrites a path, a retag rewrites two fields — and
/// the result is as accurate as a rescan would have been, without one.
///
/// That removes the failure this app has hit more than any other: a plan
/// built from paths a previous run had already changed, applied again,
/// failing on every single file. The scan does not go stale, because it
/// is brought along.
///
/// ## What it does not do
///
/// It never decides anything. [TrackIndex] is a value type, and
/// [afterJournal] is a pure function of an index and a list of journal
/// entries — so the rules below can be checked without a filesystem,
/// which is the only way to have any confidence in them.
library;

import 'dart:convert';

import 'apply.dart';
import 'plan.dart';
import 'track.dart';

/// The format version written into the file.
///
/// Bumped when a change makes an older index wrong rather than merely
/// incomplete — a different fingerprint algorithm, say. An index from a
/// newer version is ignored rather than misread.
const int kIndexVersion = 1;

/// What one scan knew, in a form that can be saved and edited.
class TrackIndex {
  const TrackIndex({
    required this.rootPath,
    required this.scannedAt,
    required this.tracks,
    this.embeddedArt = const {},
    this.artChecked = const {},
    this.folderImages = const {},
    this.scanSeconds = 0,
  });

  final String rootPath;
  final DateTime scannedAt;

  /// In path order, as the scanner produced them. The order matters:
  /// collision handling in [buildPlan] depends on it, so a reloaded
  /// index must plan identically to the scan it came from.
  final List<Track> tracks;

  /// Paths carrying embedded art, mapped to its mimetype.
  final Map<String, String> embeddedArt;

  /// Paths the art pass has actually looked at.
  ///
  /// Separate from [embeddedArt] because absence from that map has two
  /// meanings — "checked, has none" and "never checked" — and
  /// conflating them would make an incremental art pass either skip
  /// files it had never read or re-read every file it had.
  final Set<String> artChecked;

  /// Folder → the likeliest cover image in it.
  final Map<String, String> folderImages;

  final int scanSeconds;

  Map<String, Track> get byPath => {for (final t in tracks) t.path: t};

  bool get isEmpty => tracks.isEmpty;

  TrackIndex withTracks(List<Track> next) => TrackIndex(
        rootPath: rootPath,
        scannedAt: scannedAt,
        tracks: next,
        embeddedArt: embeddedArt,
        artChecked: artChecked,
        folderImages: folderImages,
        scanSeconds: scanSeconds,
      );

  /// The index brought up to date with what a run actually did.
  ///
  /// Driven by the journal rather than by the plan, which is the whole
  /// point: the plan says what was intended and the journal says what
  /// happened, and on a collection this size those differ often enough
  /// that guessing from the plan would quietly corrupt the index.
  ///
  /// Failed entries are skipped. A failure leaves the file exactly where
  /// it was — [applyPlan] guarantees that, including undoing a copy
  /// whose original could not be removed — so there is nothing to
  /// record.
  ///
  /// [applied] is the plan that produced those entries, and is needed
  /// for exactly one thing: a journal entry for a retag records what the
  /// tags *were*, because that is what undo needs, and the index needs
  /// what they *became*. Without it a retagged file keeps its old values
  /// in the index and the very same retag is planned again on the next
  /// pass, which looks like the write silently failed.
  TrackIndex afterJournal(
    Iterable<JournalEntry> entries, {
    Plan? applied,
  }) {
    final intended = <String, PlannedAction>{
      for (final a in applied?.all ?? const <PlannedAction>[])
        '${a.kind.name}:${a.path}': a,
    };
    final byPath = {for (final t in tracks) t.path: t};
    final art = Map<String, String>.from(embeddedArt);
    final checked = Set<String>.from(artChecked);
    final images = Map<String, String>.from(folderImages);

    // Order matters here for the same reason it matters in the applier:
    // a file retagged and then moved has journal entries naming two
    // different paths, and replaying them in the order they were
    // written is the only way both land on the right track.
    for (final e in entries) {
      if (!e.succeeded) continue;

      switch (e.kind) {
        case ActionKind.move:
          // Read before removing. Removing first and then bailing out
          // on a missing target deleted the track from the index — the
          // file still on disk, the app no longer aware of it.
          final to = e.targetPath;
          final track = to == null ? null : byPath.remove(e.path);
          if (track == null || to == null) break;
          // The stamp is deliberately cleared. A move does not change a
          // file's contents, but it can change its modification time —
          // a copy-and-delete across filesystems certainly does — and a
          // stamp that is wrong in the optimistic direction means a
          // changed file never gets re-read. Zero means "re-read it",
          // which costs one file and is always safe.
          byPath[to] = track.copyWith(path: to, modifiedMs: 0);
          _moveArt(art, checked, e.path, to);

        case ActionKind.trash:
          // Gone from the collection's point of view. It still exists,
          // in the trash folder, and undo puts it back — at which point
          // this same journal is replayed in reverse.
          byPath.remove(e.path);
          art.remove(e.path);
          checked.remove(e.path);

        case ActionKind.retag:
          final track = byPath[e.path];
          if (track == null) break;
          final wrote = intended['retag:${e.path}'];
          // The stamp is cleared either way, because writing tags
          // rewrites the file. The values are only updated when the
          // plan is at hand to say what they became; without it the
          // cleared stamp still forces a re-read, so the index ends up
          // correct either way — just more slowly.
          byPath[e.path] = track.copyWith(
            modifiedMs: 0,
            artist: wrote?.artist,
            title: wrote?.title,
            genres: wrote?.genres,
          );

        case ActionKind.embedArt:
          // The mimetype is not in the journal, and the only thing that
          // reads this map cares whether a cover is there. JPEG is what
          // every path through this app writes except a PNG donor, and
          // a wrong guess here costs a cover file named `.jpg` holding
          // a PNG — so the art pass re-reads these rather than trusting
          // the guess.
          checked.remove(e.path);
          final track = byPath[e.path];
          if (track != null) {
            byPath[e.path] = track.copyWith(modifiedMs: 0);
          }

        case ActionKind.writeCover:
          final slash = e.path.lastIndexOf('/');
          if (slash <= 0) break;
          images[e.path.substring(0, slash)] = e.path;
      }
    }

    // Back into path order, so a plan built from this index is the plan
    // that would have been built from a fresh scan.
    final next = byPath.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    return TrackIndex(
      rootPath: rootPath,
      scannedAt: scannedAt,
      tracks: next,
      embeddedArt: art,
      artChecked: checked,
      folderImages: images,
      scanSeconds: scanSeconds,
    );
  }

  /// The same index with freshly read size and modification times.
  ///
  /// The companion to [afterJournal]'s cleared stamps. Writing tags or
  /// moving a file changes its stamp, and an index that does not know
  /// the new one re-reads the file on the next scan — 3.7ms a file, for
  /// information it already has. Re-`stat`ing the handful of files a run
  /// touched costs microseconds each, so the index stays both correct
  /// and complete.
  ///
  /// A path missing from [stamps] keeps its cleared stamp and is
  /// re-read, which is the safe direction.
  TrackIndex withFreshStamps(Map<String, (int size, int modifiedMs)> stamps) =>
      withTracks([
        for (final t in tracks)
          if (stamps[t.path] case (final size, final modified))
            t.copyWith(sizeBytes: size, modifiedMs: modified)
          else
            t,
      ]);

  static void _moveArt(
    Map<String, String> art,
    Set<String> checked,
    String from,
    String to,
  ) {
    final mime = art.remove(from);
    if (mime != null) art[to] = mime;
    if (checked.remove(from)) checked.add(to);
  }

  Map<String, Object?> toJson() => {
        'version': kIndexVersion,
        'root': rootPath,
        'at': scannedAt.toIso8601String(),
        'scanSeconds': scanSeconds,
        'tracks': [for (final t in tracks) t.toJson()],
        if (embeddedArt.isNotEmpty) 'art': embeddedArt,
        if (artChecked.isNotEmpty) 'artChecked': artChecked.toList(),
        if (folderImages.isNotEmpty) 'folderImages': folderImages,
      };

  /// Reads an index, or null when it cannot be used.
  ///
  /// Null rather than an exception, and null rather than a partial
  /// index: this is a cache, and the correct response to a cache that
  /// cannot be read is to rebuild it. The only cost of returning null is
  /// one slow scan.
  static TrackIndex? fromJson(Map<String, Object?> j) {
    final version = (j['version'] as num?)?.toInt() ?? 0;
    // Written by a newer build. Its tracks may mean something different
    // — a changed fingerprint, a new field the planner relies on — so it
    // is rebuilt rather than guessed at.
    if (version != kIndexVersion) return null;

    final root = j['root'];
    if (root is! String || root.isEmpty) return null;

    final rows = j['tracks'];
    if (rows is! List) return null;

    final tracks = <Track>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final t = Track.fromJson(raw.cast<String, Object?>());
      // One unreadable row costs that row. Losing five thousand good
      // ones because of one bad line is the behaviour worth avoiding.
      if (t != null) tracks.add(t);
    }

    return TrackIndex(
      rootPath: root,
      scannedAt: DateTime.tryParse('${j['at']}') ?? DateTime(2000),
      tracks: tracks,
      embeddedArt: _stringMap(j['art']),
      artChecked: {
        for (final p in (j['artChecked'] as List?) ?? const [])
          if (p is String) p,
      },
      folderImages: _stringMap(j['folderImages']),
      scanSeconds: (j['scanSeconds'] as num?)?.toInt() ?? 0,
    );
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }
}

String encodeIndex(TrackIndex index) => jsonEncode(index.toJson());

TrackIndex? decodeIndex(String source) {
  try {
    final root = jsonDecode(source);
    if (root is! Map) return null;
    return TrackIndex.fromJson(root.cast<String, Object?>());
  } catch (_) {
    return null;
  }
}

/// How much of a rescan was answered from the index.
class ReuseStats {
  const ReuseStats({
    required this.reused,
    required this.read,
    required this.vanished,
  });

  /// Files the index already knew and that `stat` said were unchanged.
  final int reused;

  /// Files that had to be opened and read — new, or changed since.
  final int read;

  /// Files the index knew that are no longer there.
  final int vanished;

  int get total => reused + read;

  bool get everythingReused => read == 0 && reused > 0;

  /// For the line on screen. Worth showing because a scan that finishes
  /// in two seconds where it used to take three minutes looks like it
  /// failed, and saying what happened is cheaper than explaining it.
  String describe() {
    if (total == 0) return 'nothing found';
    if (read == 0) return '$reused files, none changed — nothing re-read';
    if (reused == 0) return '$read files read';
    return '$read changed, $reused unchanged';
  }
}
