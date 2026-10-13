/// Working out what to change, before changing anything.
///
/// The whole app is arranged around this type. Nothing touches a file
/// until a [Plan] has been built, shown, and confirmed — because the
/// alternative, on a collection of five thousand irreplaceable files with
/// no backup, is a rename rule that was subtly wrong applied five
/// thousand times before anyone noticed.
///
/// Planning is a pure function of the scanned tracks. That means the
/// whole of it is testable, and that a plan can be computed, serialised,
/// read on screen and applied later without the filesystem having been
/// consulted in between.
library;

import 'bitrate.dart';
import 'duplicates.dart';
import 'track.dart';

/// What kind of change one action makes.
enum ActionKind {
  /// Move or rename the file.
  move,

  /// Write tags in place.
  retag,

  /// Move a file to the trash directory.
  trash,
}

/// One change, described completely enough to be shown, applied, and
/// reversed.
class PlannedAction {
  const PlannedAction({
    required this.kind,
    required this.path,
    this.targetPath,
    this.artist,
    this.title,
    this.genres,
    this.reason = '',
  });

  final ActionKind kind;

  /// Where the file is now.
  final String path;

  /// Where it will be. Null for a retag, which does not move anything.
  final String? targetPath;

  /// New tag values, where they differ from what is on the file. Null
  /// means "leave this field alone" — distinct from an empty string,
  /// which would mean "clear it".
  final String? artist;
  final String? title;
  final List<String>? genres;

  /// Why, in words, for the review list. A plan nobody can read is a
  /// plan nobody can check.
  final String reason;

  bool get changesTags =>
      artist != null || title != null || genres != null;
}

/// Everything that would be done, grouped so it can be approved in parts.
class Plan {
  const Plan({
    required this.moves,
    required this.retags,
    required this.trashes,
    required this.artistMerges,
    required this.unsortable,
  });

  final List<PlannedAction> moves;
  final List<PlannedAction> retags;
  final List<PlannedAction> trashes;

  /// Spelling variants that would be standardised, as canonical → the
  /// variants being folded into it. Shown separately because it is the
  /// change most likely to be wrong, and the one a person can judge at a
  /// glance.
  final Map<String, List<String>> artistMerges;

  /// Files with too little information to file, left exactly where they
  /// are. Reported rather than dumped somewhere, because a folder called
  /// `_unsorted` that silently accumulates is how things get lost.
  final List<Track> unsortable;

  int get actionCount => moves.length + retags.length + trashes.length;
  bool get isEmpty => actionCount == 0;

  List<PlannedAction> get all => [...moves, ...retags, ...trashes];
}

/// How the planner should behave.
class PlanOptions {
  const PlanOptions({
    this.root = '',
    this.renameFiles = true,
    this.writeTags = true,
    this.tagQuality = true,
    this.standardiseArtists = true,
    this.removeDuplicates = false,
    this.trashDirName = '.mp3sorter-trash',
  });

  /// Where tidied files are filed, as `root/Artist/Title.mp3`.
  final String root;

  final bool renameFiles;
  final bool writeTags;
  final bool tagQuality;
  final bool standardiseArtists;

  /// Off by default. Deleting is the one action that cannot be undone by
  /// moving a file back, so it is opt-in even inside a plan that is
  /// reviewed before it runs.
  final bool removeDuplicates;

  /// Removed files go here rather than being unlinked, so "undo" means
  /// moving them back rather than restoring from a backup nobody has.
  final String trashDirName;
}

/// Builds the plan.
///
/// Pure: same tracks in, same plan out, no filesystem access. The one
/// consequence worth knowing is that collision handling depends on the
/// order of [tracks], so the caller should hand them over sorted.
Plan buildPlan(List<Track> tracks, PlanOptions options) {
  final moves = <PlannedAction>[];
  final retags = <PlannedAction>[];
  final trashes = <PlannedAction>[];
  final unsortable = <Track>[];

  final canonical = options.standardiseArtists
      ? canonicalArtists(tracks)
      : const <String, String>{};

  final merges = <String, List<String>>{};
  canonical.forEach((variant, target) {
    if (variant == target) return;
    merges.putIfAbsent(target, () => []).add(variant);
  });
  for (final v in merges.values) {
    v.sort();
  }

  // Duplicates are decided first, so a file about to be trashed is not
  // also planned a move — two actions on one path is how a plan half
  // applies and leaves a mess.
  final doomed = <String>{};
  if (options.removeDuplicates) {
    for (final group in findDuplicates(tracks)) {
      for (final t in group.discard) {
        doomed.add(t.path);
        trashes.add(PlannedAction(
          kind: ActionKind.trash,
          path: t.path,
          targetPath: '${options.root}/${options.trashDirName}/'
              '${safeComponent(t.path.split('/').last)}',
          reason: switch (group.kind) {
            DuplicateKind.identicalFile =>
              'identical to ${group.keep.path.split('/').last}',
            DuplicateKind.sameAudio =>
              'same audio as ${group.keep.path.split('/').last}, '
                  'different tags',
            DuplicateKind.sameSong =>
              'same song as ${group.keep.path.split('/').last} '
                  '(${group.keep.bitrateKbps}k vs ${t.bitrateKbps}k)',
          },
        ));
      }
    }
  }

  // Claimed target paths, so two tracks cannot be planned onto one name.
  final claimed = <String>{};

  for (final track in tracks) {
    if (doomed.contains(track.path)) continue;
    if (!track.isReadable) {
      unsortable.add(track);
      continue;
    }

    final names = inferNames(track);
    final rawArtist = names.artist;
    final artist =
        rawArtist == null ? null : (canonical[rawArtist] ?? rawArtist);
    final title = names.title;

    // ---- tags -------------------------------------------------------
    if (options.writeTags) {
      String? newArtist;
      String? newTitle;
      List<String>? newGenres;

      if (artist != null && artist != track.artist) newArtist = artist;
      if (title != null && title != track.title) newTitle = title;

      if (options.tagQuality && track.band != null) {
        final wanted = applyQualityTag(track.genres, track.band!);
        if (!_sameList(wanted, track.genres)) newGenres = wanted;
      }

      if (newArtist != null || newTitle != null || newGenres != null) {
        retags.add(PlannedAction(
          kind: ActionKind.retag,
          path: track.path,
          artist: newArtist,
          title: newTitle,
          genres: newGenres,
          reason: _retagReason(track, newArtist, newTitle, newGenres),
        ));
      }
    }

    // ---- filing -----------------------------------------------------
    if (!options.renameFiles) continue;

    // Both halves are needed to file a track. A guess at one of them
    // produces `Unknown Artist/Unknown Title.mp3`, which is worse than
    // leaving the file alone: it destroys the one clue left, the
    // original filename.
    if (artist == null || artist.isEmpty || title == null || title.isEmpty) {
      unsortable.add(track);
      continue;
    }

    final extension = _extensionOf(track.path);
    var target = '${options.root}/${safeComponent(artist)}/'
        '${safeComponent(title)}$extension';

    if (target == track.path) continue;

    target = _disambiguate(target, extension, claimed, track);
    claimed.add(target.toLowerCase());

    moves.add(PlannedAction(
      kind: ActionKind.move,
      path: track.path,
      targetPath: target,
      reason: names.fromTags
          ? 'from tags'
          : 'from the filename — tags were missing',
    ));
  }

  return Plan(
    moves: moves,
    retags: retags,
    trashes: trashes,
    artistMerges: merges,
    unsortable: unsortable,
  );
}

/// Finds a free name when two tracks want the same one.
///
/// Compared case-insensitively, because two files differing only in case
/// coexist on ext4 and collide on the FAT card this collection might end
/// up on — planning them onto one name would silently lose one.
///
/// The suffix carries the bitrate rather than a bare counter, because
/// `Title (128k).mp3` beside `Title.mp3` says what the second copy is,
/// where `Title (2).mp3` says only that there was one.
String _disambiguate(
  String target,
  String extension,
  Set<String> claimed,
  Track track,
) {
  if (!claimed.contains(target.toLowerCase())) return target;

  final base = target.substring(0, target.length - extension.length);

  if (track.bitrateKbps != null) {
    final withRate = '$base (${track.bitrateKbps}k)$extension';
    if (!claimed.contains(withRate.toLowerCase())) return withRate;
  }

  for (var n = 2; n < 1000; n++) {
    final candidate = '$base ($n)$extension';
    if (!claimed.contains(candidate.toLowerCase())) return candidate;
  }
  // A thousand files wanting one name is not a real collection; giving
  // up loudly beats looping.
  return '$base (${track.sizeBytes})$extension';
}

String _extensionOf(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

String _retagReason(
  Track track,
  String? artist,
  String? title,
  List<String>? genres,
) {
  final bits = <String>[];
  if (artist != null) bits.add('artist → $artist');
  if (title != null) bits.add('title → $title');
  if (genres != null) {
    final had = track.genres.contains(kLowQualityTag);
    final will = genres.contains(kLowQualityTag);
    if (will && !had) {
      bits.add('mark ${track.bitrateKbps}k as $kLowQualityTag');
    } else if (had && !will) {
      bits.add('clear $kLowQualityTag');
    } else {
      bits.add('genres');
    }
  }
  return bits.join(', ');
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Problems worth refusing to apply over.
///
/// Checked after planning and before applying, because a plan built from
/// stale data — files moved by something else since the scan — can
/// contain contradictions that would half-apply.
class PlanProblem {
  const PlanProblem(this.message, this.paths);
  final String message;
  final List<String> paths;
}

List<PlanProblem> validatePlan(Plan plan) {
  final problems = <PlanProblem>[];

  // Two actions moving different files to one place.
  final targets = <String, List<String>>{};
  for (final m in plan.moves) {
    targets.putIfAbsent(m.targetPath!.toLowerCase(), () => []).add(m.path);
  }
  for (final entry in targets.entries) {
    if (entry.value.length > 1) {
      problems.add(PlanProblem(
        'two files would be moved onto ${entry.key}',
        entry.value,
      ));
    }
  }

  // One file appearing in two actions of the same kind.
  for (final kind in ActionKind.values) {
    final seen = <String>{};
    final twice = <String>[];
    for (final a in plan.all.where((a) => a.kind == kind)) {
      if (!seen.add(a.path)) twice.add(a.path);
    }
    if (twice.isNotEmpty) {
      problems.add(PlanProblem('planned twice as ${kind.name}', twice));
    }
  }

  // A file both moved and thrown away.
  final trashed = {for (final t in plan.trashes) t.path};
  final movedAndTrashed = [
    for (final m in plan.moves)
      if (trashed.contains(m.path)) m.path,
  ];
  if (movedAndTrashed.isNotEmpty) {
    problems.add(
        PlanProblem('both moved and trashed', movedAndTrashed));
  }

  return problems;
}
