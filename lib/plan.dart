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
import 'levenshtein.dart';
import 'track.dart';

/// What kind of change one action makes.
enum ActionKind {
  /// Move or rename the file.
  move,

  /// Write tags in place.
  retag,

  /// Move a file to the trash directory.
  trash,

  /// Write a cover image into a file's tags.
  embedArt,

  /// Create a cover image file beside an album.
  writeCover,
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
    this.artFrom,
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

  /// Where a cover's bytes come from, for [ActionKind.embedArt] and
  /// [ActionKind.writeCover]. Either an audio file carrying embedded art
  /// or an image file.
  ///
  /// A path rather than the bytes themselves, so an art action is the
  /// same size as any other and a plan with a thousand of them can be
  /// held, shown and written to a session file without carrying a
  /// hundred megabytes of JPEG through the app.
  final String? artFrom;

  /// Why, in words, for the review list. A plan nobody can read is a
  /// plan nobody can check.
  final String reason;

  bool get changesTags =>
      artist != null || title != null || genres != null;

  bool get isArt =>
      kind == ActionKind.embedArt || kind == ActionKind.writeCover;
}

/// Everything that would be done, grouped so it can be approved in parts.
class Plan {
  const Plan({
    required this.moves,
    required this.retags,
    required this.trashes,
    this.art = const [],
    required this.artistMerges,
    required this.unsortable,
    this.stationaryPaths = const {},
    this.blockedMoves = const [],
    this.occupiedPaths = const {},
  });

  final List<PlannedAction> moves;
  final List<PlannedAction> retags;
  final List<PlannedAction> trashes;

  /// Cover art to write. Empty unless art collection was run — it is a
  /// separate, explicit step, because it is the only part of this app
  /// that can reach the network.
  final List<PlannedAction> art;

  /// Spelling variants that would be standardised, as canonical → the
  /// variants being folded into it. Shown separately because it is the
  /// change most likely to be wrong, and the one a person can judge at a
  /// glance.
  final Map<String, List<String>> artistMerges;

  /// Files with too little information to file, left exactly where they
  /// are. Reported rather than dumped somewhere, because a folder called
  /// `_unsorted` that silently accumulates is how things get lost.
  final List<Track> unsortable;

  /// Paths occupied by files that are *not* moving — because they are
  /// already where they belong, or because nothing could be worked out
  /// about them.
  ///
  /// Carried on the plan so [validatePlan] can catch a move aimed at an
  /// occupied name. Without it, a file already correctly named looks
  /// invisible to the planner and the next file with the same tags gets
  /// planned straight on top of it.
  final Set<String> stationaryPaths;

  /// Moves that could not be safely ordered because they form a rename
  /// cycle. Shown rather than attempted — see [orderMoves].
  final List<PlannedAction> blockedMoves;

  /// Every path the scan found a file on. Carried so [validatePlan] can
  /// assert the invariant that failed four times: a move's destination
  /// must be free when it runs.
  final Set<String> occupiedPaths;

  int get actionCount =>
      moves.length + retags.length + trashes.length + art.length;
  bool get isEmpty => actionCount == 0;

  List<PlannedAction> get all => [...moves, ...retags, ...trashes, ...art];

  /// The same plan with art actions attached. Art is collected after a
  /// plan has been built, so it arrives separately rather than being
  /// threaded back through [buildPlan].
  Plan withArt(List<PlannedAction> actions) => Plan(
        moves: moves,
        retags: retags,
        trashes: trashes,
        art: actions,
        artistMerges: artistMerges,
        unsortable: unsortable,
        stationaryPaths: stationaryPaths,
        blockedMoves: blockedMoves,
        occupiedPaths: occupiedPaths,
      );
}

/// Where a tidied file ends up.
enum Layout {
  /// `Artist/Title.mp3`. Flat per artist — fine for singles and loose
  /// tracks, and it merges albums together.
  artistTitle,

  /// `Artist/Album/01 Title.mp3`. Keeps albums apart and restores track
  /// order, which is also what stops two songs of the same name on
  /// different records fighting over one filename.
  artistAlbumTitle,
}

/// How the planner should behave.
class PlanOptions {
  const PlanOptions({
    this.root = '',
    this.sourceRoot = '',
    this.layout = Layout.artistAlbumTitle,
    this.useFolderHints = true,
    this.renameFiles = true,
    this.writeTags = true,
    this.cleanQualityTags = true,
    this.standardiseArtists = true,
    this.removeDuplicates = false,
    this.trashDirName = '.mp3sorter-trash',
  });

  /// Where tidied files are filed, under [layout].
  final String root;

  /// The folder that was scanned. Needed to work out which folders above
  /// a file are its own rather than part of the path to the collection.
  final String sourceRoot;

  final Layout layout;

  /// Fall back to the folder structure when a tag is missing. The
  /// immediate parent is read as the album and the one above it as the
  /// artist — see [folderHints] for why it refuses to go further.
  final bool useFolderHints;

  final bool renameFiles;
  final bool writeTags;
  /// Remove any `low quality` genre an earlier version of this app
  /// wrote. Nothing adds one any more — quality is computed at scan time
  /// and never persisted — so this only ever takes something back.
  final bool cleanQualityTags;
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

  // Names this planner has handed out. Separate from what is on disk —
  // see [_disambiguate] for why conflating the two was a bug.
  final claimed = <String>{};

  /// Every path a scanned file currently sits on. Never removed from:
  /// a file only stops occupying its path once its move has actually
  /// run, and the planner cannot know the order that will happen in.
  final occupied = <String>{for (final t in tracks) t.path.toLowerCase()};

  /// Tracks that can be filed, with the names to file them under.
  /// Collected in the first pass and assigned targets in the second.
  final wanted = <(Track, String, String, String?, bool, bool)>[];

  for (final track in tracks) {
    if (doomed.contains(track.path)) continue;
    if (!track.isReadable) {
      unsortable.add(track);
      continue;
    }

    final names = inferNames(track);
    final hints = options.useFolderHints
        ? folderHints(track.path, options.sourceRoot)
        : const FolderHints();

    // Tags first, then the filename, then the folders. Each step is a
    // weaker claim than the one before it, so the order matters.
    final rawArtist = names.artist ?? hints.artist;
    final artist =
        rawArtist == null ? null : (canonical[rawArtist] ?? rawArtist);
    final title = names.title;
    final album = track.album?.trim().isNotEmpty == true
        ? track.album!.trim()
        : hints.album;
    final guessedFromFolder =
        (names.artist == null && hints.artist != null) ||
            (track.album?.trim().isNotEmpty != true && hints.album != null);

    // ---- tags -------------------------------------------------------
    if (options.writeTags) {
      String? newArtist;
      String? newTitle;
      List<String>? newGenres;

      if (artist != null && artist != track.artist) newArtist = artist;
      if (title != null && title != track.title) newTitle = title;

      // Quality is no longer written anywhere. The only genre change
      // this app makes is removing a marker it should not have written.
      if (options.cleanQualityTags && hasQualityTag(track.genres)) {
        newGenres = stripQualityTags(track.genres);
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

    // Filing happens in a second pass below, because where a file can go
    // depends on which names are already taken by files that are not
    // moving — which is not known until every track has been considered.
    if (options.renameFiles) {
      if (artist == null ||
          artist.isEmpty ||
          title == null ||
          title.isEmpty) {
        // Both halves are needed to file a track. A guess at one of them
        // produces `Unknown Artist/Unknown Title.mp3`, which is worse
        // than leaving the file alone: it destroys the one clue left,
        // the original filename.
        unsortable.add(track);
      } else {
        wanted.add(
            (track, artist, title, album, names.fromTags, guessedFromFolder));
      }
    }
  }

  /// Where a track belongs, under the chosen layout.
  ///
  /// The album folder is used only when the file actually carries an
  /// album tag. A file with none goes straight under the artist rather
  /// than into an invented `Unknown Album` — a folder named after
  /// missing information is worse than no folder, because it looks like
  /// a real album until you open it.
  ///
  /// The folder a file currently sits in is deliberately not consulted.
  /// `[2005] Wolfmother` plainly says who the artist is, but reading it
  /// would mean guessing from something nobody promised was accurate,
  /// and a wrong guess files a track under an artist that does not
  /// exist.
  String targetFor(Track track, String artist, String title, String? album) {
    final extension = _extensionOf(track.path);
    final safeTitle = safeComponent(title);

    // A single, where the album is named after its one track, gets no
    // album folder: `Creepy Nuts/Bling-Bang-Bang-Born/Bling-Bang-Bang-Born.mp3`
    // is a directory that exists to hold a file of the same name.
    // Compared after normalisation, since the two spellings rarely match
    // character for character.
    final albumIsTheTitle = album != null &&
        normaliseForMatching(album) == normaliseForMatching(title);

    if (options.layout == Layout.artistTitle ||
        album == null ||
        album.isEmpty ||
        albumIsTheTitle) {
      return '${options.root}/${safeComponent(artist)}/$safeTitle$extension';
    }

    // Zero-padded so a plain alphabetical listing is in album order,
    // which is the only reason the number is in the name at all.
    // The tag first, then whatever the filename was carrying.
    final number = track.trackNumber ?? inferNames(track).trackNumber;
    final prefix = number == null || number <= 0
        ? ''
        : '${number.toString().padLeft(2, '0')} ';

    return '${options.root}/${safeComponent(artist)}/'
        '${safeComponent(album)}/$prefix$safeTitle$extension';
  }

  // ---- filing, pass two ----------------------------------------------
  //
  // Two passes, and the reason is a bug this had in 1.0.x. A file already
  // sitting at its correct name used to be skipped without reserving that
  // name, so the next file with identical tags saw it as free, was
  // planned straight onto it, and failed at apply time with "something
  // already exists". On a collection rescanned after a previous run that
  // cascaded: 120 failures in one go.
  //
  // So every name that will still be occupied afterwards is claimed
  // first, and only then are moves assigned.
  final stationary = <String>{};
  for (final t in unsortable) {
    stationary.add(t.path.toLowerCase());
  }
  for (final (track, artist, title, album, _, _) in wanted) {
    if (targetFor(track, artist, title, album) == track.path) {
      stationary.add(track.path.toLowerCase());
    }
  }
  claimed.addAll(stationary);

  for (final (track, artist, title, album, fromTags, fromFolder) in wanted) {
    final extension = _extensionOf(track.path);
    var target = targetFor(track, artist, title, album);

    if (target == track.path) continue;

    target = _disambiguate(target, extension, claimed, occupied, track);
    claimed.add(target.toLowerCase());

    // Checked again, because disambiguation can hand a file back its own
    // name: a file already called `Title (134k).mp3` whose plain target
    // is taken disambiguates to exactly where it already is. Without
    // this the plan contains a move from a path to itself, which is both
    // noise in the review list and the reason a second run over an
    // already-tidy folder never settles.
    if (target == track.path) continue;

    moves.add(PlannedAction(
      kind: ActionKind.move,
      path: track.path,
      targetPath: target,
      reason: fromFolder
          // Flagged, because this is the weakest of the three sources
          // and the one most worth a glance before it is acted on.
          ? 'from the folder name — check this one'
          : fromTags
              ? 'from tags'
              : 'from the filename — tags were missing',
    ));
  }

  // Moves are reordered so a file never lands on a name that is still
  // occupied when its turn comes. See [orderMoves]. With the planner no
  // longer targeting occupied names this should find nothing to do, and
  // it stays as the backstop that proves it.
  final ordered = orderMoves(moves, occupied);

  return Plan(
    moves: ordered.ordered,
    retags: retags,
    trashes: trashes,
    artistMerges: merges,
    unsortable: unsortable,
    stationaryPaths: stationary,
    blockedMoves: ordered.blocked,
    occupiedPaths: occupied,
  );
}

/// The result of working out a safe order for a set of moves.
class OrderedMoves {
  const OrderedMoves(this.ordered, this.blocked);

  /// Moves in an order where each one's target is free by the time it
  /// runs.
  final List<PlannedAction> ordered;

  /// Moves that cannot be placed in any safe order, because they form a
  /// cycle — two files swapping names, or a longer ring. Dropped rather
  /// than attempted: carrying them out needs a temporary name, and
  /// inventing one for a case this rare is more machinery than the
  /// problem deserves. They are reported so they can be settled by hand
  /// or as duplicates.
  final List<PlannedAction> blocked;
}

/// Orders moves so each one's destination is free when it runs.
///
/// The bug this exists for, seen on a device twice. Three files share
/// one set of tags, so they compete for one name and get disambiguated
/// suffixes. On a rescan the planner reassigns those suffixes — and the
/// assignment is a *permutation of names that already exist*:
///
/// ```
/// Megitsune (2).mp3     -> Megitsune (320k).mp3   ← occupied right now
/// Megitsune (320k).mp3  -> Megitsune (2).mp3      ← also occupied
/// ```
///
/// Each move is individually fine and the pair is impossible in the
/// order written. Treating a path as free because its occupant is
/// leaving is only true once the occupant has actually left.
///
/// Kahn's algorithm over "this move must wait for that one". Pure, so
/// the ordering can be tested without a filesystem.
OrderedMoves orderMoves(
  List<PlannedAction> moves,
  Set<String> occupiedNow,
) {
  // Which move frees which path.
  final vacatedBy = <String, PlannedAction>{
    for (final m in moves) m.path.toLowerCase(): m,
  };

  // A move must wait for whichever move is vacating its target. A target
  // nobody currently occupies has nothing to wait for. At most one thing
  // can occupy a path, so this is one dependency per move, not a list.
  final waitsFor = <PlannedAction, PlannedAction?>{};
  // And the other direction: who is waiting on this move to finish.
  final waitedOnBy = <PlannedAction, List<PlannedAction>>{
    for (final m in moves) m: <PlannedAction>[],
  };

  for (final m in moves) {
    final target = m.targetPath!.toLowerCase();
    final dependency = occupiedNow.contains(target) ? vacatedBy[target] : null;
    // A move onto its own path depends on nothing; the planner drops
    // those anyway, but the ordering must not deadlock on one.
    if (dependency == null || identical(dependency, m)) {
      waitsFor[m] = null;
    } else {
      waitsFor[m] = dependency;
      waitedOnBy[dependency]!.add(m);
    }
  }

  // Kahn's algorithm, forwards. Original order is preserved among moves
  // with nothing to wait for, so a plan with no constraints comes back
  // unchanged and the review list does not reshuffle for no reason.
  final ready = [for (final m in moves) if (waitsFor[m] == null) m];
  final ordered = <PlannedAction>[];
  final done = <PlannedAction>{};

  while (ready.isNotEmpty) {
    final m = ready.removeAt(0);
    if (!done.add(m)) continue;
    ordered.add(m);
    for (final waiter in waitedOnBy[m]!) {
      if (!done.contains(waiter)) ready.add(waiter);
    }
  }

  // Whatever never became ready is in a cycle.
  final blocked = [for (final m in moves) if (!done.contains(m)) m];

  return OrderedMoves(ordered, blocked);
}

/// Finds a free name when two tracks want the same one.
///
/// Two separate notions of "taken", and conflating them was a bug that
/// reached a device four times:
///
///  * **[assigned]** — names this planner has already given to a move.
///  * **[occupied]** — names files are sitting on right now.
///
/// A file may be given a name it already occupies; that is how a file
/// stays put. It may not be given a name *another* file occupies, even
/// if that file looks like it is leaving — whether it leaves depends on
/// decisions not yet made, and the version that assumed otherwise
/// planned moves onto files that never moved.
///
/// Compared case-insensitively, because two files differing only in case
/// coexist on ext4 and collide on a FAT card — planning them onto one
/// name would silently lose one.
///
/// The suffix carries the bitrate rather than a bare counter, because
/// `Title (128k).mp3` beside `Title.mp3` says what the second copy is,
/// where `Title (2).mp3` says only that there was one.
String _disambiguate(
  String target,
  String extension,
  Set<String> assigned,
  Set<String> occupied,
  Track track,
) {
  final own = track.path.toLowerCase();

  bool free(String candidate) {
    final c = candidate.toLowerCase();
    if (assigned.contains(c)) return false;
    // Occupied by somebody else is the hard stop. Occupied by this very
    // file is not an obstacle to itself.
    return !occupied.contains(c) || c == own;
  }

  if (free(target)) return target;

  final base = target.substring(0, target.length - extension.length);

  if (track.bitrateKbps != null) {
    final withRate = '$base (${track.bitrateKbps}k)$extension';
    if (free(withRate)) return withRate;
  }

  for (var n = 2; n < 1000; n++) {
    final candidate = '$base ($n)$extension';
    if (free(candidate)) return candidate;
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
    bits.add('remove the "$kLowQualityTag" genre this app added');
  }
  return bits.join(', ');
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

  // The invariant that failed four times, checked directly: walk the
  // plan the way the applier will and confirm every destination is free
  // at the moment its move runs. This catches the whole family at once,
  // however a future change manages to reintroduce it.
  final onDisk = {...plan.occupiedPaths};
  final collisions = <String>[];
  for (final m in plan.moves) {
    final target = m.targetPath!.toLowerCase();
    if (onDisk.contains(target) && target != m.path.toLowerCase()) {
      collisions.add('${m.path} -> ${m.targetPath}');
    }
    onDisk.remove(m.path.toLowerCase());
    onDisk.add(target);
  }
  if (collisions.isNotEmpty) {
    problems.add(PlanProblem(
      'would land on a file that is still there',
      collisions,
    ));
  }

  // Art and moves in one plan. Both are legitimate; together they are
  // ambiguous, because a cover is written beside the folder a file is in
  // *now* and a move changes which folder that is. Rather than guess,
  // they are kept to separate runs — art is applied on its own.
  if (plan.art.isNotEmpty && (plan.moves.isNotEmpty || plan.trashes.isNotEmpty)) {
    problems.add(PlanProblem(
      'cover art and file moves cannot be applied in one run — '
      'the cover would be written beside where the files used to be',
      [for (final a in plan.art.take(5)) a.path],
    ));
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
