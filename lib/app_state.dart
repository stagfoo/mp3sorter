/// What the screens read from.
///
/// Holds the scan, the plan and the journal, and nothing else. All the
/// decisions live in the pure modules — this only sequences them and
/// reports progress.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'apply.dart';
import 'artwork.dart';
import 'bitrate.dart';
import 'cover_art.dart';
import 'diagnostics.dart';
import 'duplicates.dart';
import 'index_store.dart';
import 'levenshtein.dart';
import 'plan.dart';
import 'recent_folders.dart';
import 'scanner.dart';
import 'session_file.dart';
import 'track_index.dart';
import 'version.dart';
import 'track.dart';

enum Stage { idle, scanning, scanned, applying, done }

class AppState extends ChangeNotifier {
  Stage stage = Stage.idle;

  String? rootPath;
  ScanResult? scan;
  Plan? plan;
  List<DuplicateGroup> duplicates = const [];

  PlanOptions options = const PlanOptions();

  /// Which actions the person has approved. Everything starts approved —
  /// the review is for spotting what is *wrong*, and making someone tick
  /// five thousand boxes to accept a plan they agree with is how the
  /// review gets skipped entirely.
  final Set<String> rejected = {};

  int progressDone = 0;
  int progressTotal = 0;
  String progressLabel = '';

  ApplyResult? lastResult;
  bool canUndo = false;

  /// Set once a run has moved files about, which makes every path in the
  /// current scan a guess. Until a rescan, the plan cannot be applied
  /// again.
  ///
  /// The bug this fixes, seen on a real device: after a successful run
  /// the plan stayed on screen and could be pressed again, at which point
  /// every action failed with "file no longer exists" — literally true,
  /// since the first run had moved them, and completely unhelpful as an
  /// explanation. 249 failures that were entirely the app's fault.
  bool scanIsStale = false;

  /// Where the last saved scan went, for the message after saving.
  String? lastSavedPath;

  /// Folders scanned before. Loaded once at startup so the first screen
  /// can offer them without waiting on disk.
  List<RecentFolder> recentFolders = const [];

  // ------------------------------------------------------- album art

  /// What the art pass found on disk. Null until it has been run — it is
  /// a separate, slower pass than the main scan, because finding out
  /// whether a file has a cover means reading the cover.
  ArtScan? artScan;

  /// Albums, and where each one's cover would come from.
  List<AlbumArt> albums = const [];

  /// Art actions waiting to be approved and applied.
  List<PlannedAction> artPlan = const [];

  /// One line per album the online pass could not settle. Kept so "47
  /// not found" can be turned into something readable.
  List<String> artNotes = const [];

  ApplyResult? lastArtResult;

  /// Whether a lookup has been run this session. Only ever set by the
  /// person pressing the button — nothing here reaches the network on
  /// its own.
  bool artLookupRan = false;

  bool artBusy = false;

  /// Set after art has been written. The art scan describes how things
  /// were before that run, so the summary on screen is no longer true —
  /// but it is kept rather than discarded, because it is what the bug
  /// report needs and discarding it right after a run is discarding it
  /// exactly when something has gone wrong.
  bool artIsStale = false;

  ArtSummary? get artSummary =>
      artScan == null ? null : summariseArtwork(albums);

  /// Albums that only a lookup can settle.
  List<AlbumArt> get albumsNeedingLookup =>
      [for (final a in albums) if (a.needsNetwork) a];

  /// The saved index for the current collection, as it was last known
  /// to be true. Kept so a rescan can skip what has not changed, and so
  /// a run can bring it along rather than invalidating it.
  TrackIndex? index;

  /// What the last scan got for free. Shown, because a scan finishing in
  /// a second where it used to take minutes looks like it failed.
  ReuseStats? lastReuse;

  Journal? _journal;

  Future<Journal> _openJournal() async {
    if (_journal != null) return _journal!;
    final dir = await getApplicationDocumentsDirectory();
    return _journal = Journal(File('${dir.path}/mp3sorter-journal.jsonl'));
  }

  Future<void> loadRecents() async {
    final store = await RecentFoldersStore.open();
    recentFolders = await store.load();
    notifyListeners();
  }

  Future<void> forgetFolder(String path) async {
    final store = await RecentFoldersStore.open();
    recentFolders = await store.remove(path);
    // Its index goes too. Keeping one for a folder nobody is interested
    // in is a megabyte of cache that will never be read again.
    await (await IndexStore.open()).forget(path);
    notifyListeners();
  }

  /// Rescans from scratch, ignoring everything the index remembers.
  ///
  /// The escape hatch. Reuse rests on size and modification time being
  /// a true account of whether a file has changed, which is what `make`
  /// and `rsync` rest on too — but a filesystem that lies about either,
  /// or a card restored from a backup that preserved both, would leave
  /// the index quietly describing files that are not what it thinks.
  /// This is how to be sure, at the cost of the full scan time.
  Future<void> forceFullRescan() async {
    final path = rootPath;
    if (path == null) return;
    await (await IndexStore.open()).forget(path);
    index = null;
    await scanFolder(path);
  }

  Future<void> refreshUndoState() async {
    final j = await _openJournal();
    canUndo = (await j.read()).any((e) => e.succeeded);
    notifyListeners();
  }

  // ------------------------------------------------------------- scan

  Future<void> scanFolder(String path) async {
    rootPath = path;
    stage = Stage.scanning;
    progressDone = 0;
    progressTotal = 0;
    progressLabel = '';
    rejected.clear();
    notifyListeners();

    // The index first. Loading it costs one file read and saves
    // thousands — on an unchanged collection the scan below opens
    // nothing at all.
    final indexStore = await IndexStore.open();
    index = await indexStore.load(path);

    final result = await scanDirectory(
      Directory(path),
      reuse: index,
      onProgress: (done, file) {
        progressDone = done;
        progressLabel = file.split('/').last;
        // Not on every file: 5,000 notifications would spend more time
        // rebuilding the screen than reading the files.
        if (done % 25 == 0) notifyListeners();
      },
    );

    scan = result;
    lastReuse = result.reuse;
    scanIsStale = false;
    lastResult = null;

    // The art the previous index knew is carried over; the stamp check
    // inside [scanAlbumArt] is what keeps it honest.
    index = TrackIndex(
      rootPath: path,
      scannedAt: DateTime.now(),
      tracks: result.tracks,
      embeddedArt: index?.embeddedArt ?? const {},
      artChecked: index?.artChecked ?? const {},
      folderImages: index?.folderImages ?? const {},
      scanSeconds: result.elapsed.inSeconds,
    );
    await indexStore.save(index!);

    // Recorded after the scan rather than when the folder is picked, so
    // the remembered file count is a real one and a cancelled or failed
    // scan does not leave a misleading entry.
    final recents = await RecentFoldersStore.open();
    recentFolders = await recents.add(path, result.tracks.length);

    duplicates = findDuplicates(result.tracks);
    _rebuildPlan();
    stage = Stage.scanned;
    await refreshUndoState();
    notifyListeners();
  }

  void setOptions(PlanOptions next) {
    options = next;
    if (scan != null) _rebuildPlan();
    notifyListeners();
  }

  void _rebuildPlan() {
    final root = rootPath;
    if (scan == null || root == null) return;
    plan = buildPlan(
      scan!.tracks,
      PlanOptions(
        // Sorted into a subfolder of the collection, never beside it:
        // the target has to be somewhere the person can find, and
        // writing outside the folder they chose would be a surprise.
        root: '$root/${options.renameFiles ? "_sorted" : ""}',
        sourceRoot: root,
        layout: options.layout,
        useFolderHints: options.useFolderHints,
        renameFiles: options.renameFiles,
        writeTags: options.writeTags,
        cleanQualityTags: options.cleanQualityTags,
        standardiseArtists: options.standardiseArtists,
        removeDuplicates: options.removeDuplicates,
        fileUnder: fileUnder,
      ),
    );
  }

  /// Artists filed under someone else's folder by hand, keyed by
  /// [normaliseForMatching]. Kept here rather than in [options] because
  /// the settings rebuild those from scratch, and a choice made in the
  /// review should survive a toggle on the home screen.
  Map<String, String> fileUnder = const {};

  /// Files [artist] in [folder]'s folder — or, when they are the same,
  /// keeps [artist] in its own even if it shares a credit with someone.
  void fileArtistUnder(String artist, String folder) {
    fileUnder = {...fileUnder, normaliseForMatching(artist): folder};
    _rebuildPlan();
    notifyListeners();
  }

  /// Forgets a choice made with [fileArtistUnder].
  void forgetFiling(String artist) {
    fileUnder = {...fileUnder}..remove(normaliseForMatching(artist));
    _rebuildPlan();
    notifyListeners();
  }

  // ------------------------------------------------------- the review

  bool isRejected(PlannedAction a) => rejected.contains(_key(a));

  void toggle(PlannedAction a) {
    final k = _key(a);
    if (!rejected.remove(k)) rejected.add(k);
    notifyListeners();
  }

  void rejectAll(Iterable<PlannedAction> actions) {
    for (final a in actions) {
      rejected.add(_key(a));
    }
    notifyListeners();
  }

  void acceptAll(Iterable<PlannedAction> actions) {
    for (final a in actions) {
      rejected.remove(_key(a));
    }
    notifyListeners();
  }

  static String _key(PlannedAction a) => '${a.kind.name}:${a.path}';

  /// The plan with rejected actions removed — what would actually run.
  Plan get approved {
    final p = plan;
    if (p == null) {
      return const Plan(
          moves: [], retags: [], trashes: [], artistMerges: {},
          unsortable: []);
    }
    return Plan(
      moves: [for (final a in p.moves) if (!isRejected(a)) a],
      retags: [for (final a in p.retags) if (!isRejected(a)) a],
      trashes: [for (final a in p.trashes) if (!isRejected(a)) a],
      artistMerges: p.artistMerges,
      unsortable: p.unsortable,
    );
  }

  /// The art plan with rejected actions removed, as its own run.
  ///
  /// Art is applied separately from moves on purpose — see
  /// [validatePlan]. A cover is written beside the folder a file is in
  /// now, and a move changes which folder that is.
  Plan get approvedArt => Plan(
        moves: const [],
        retags: const [],
        trashes: const [],
        art: [for (final a in artPlan) if (!isRejected(a)) a],
        artistMerges: const {},
        unsortable: const [],
      );

  // ------------------------------------------------------- album art

  /// Finds out what already has art, and what can be filled from a
  /// sibling or a folder image. Touches no network.
  Future<void> scanArt() async {
    final s = scan;
    if (s == null || artBusy) return;

    artBusy = true;
    artLookupRan = false;
    artIsStale = false;
    artNotes = const [];
    lastArtResult = null;
    progressDone = 0;
    progressTotal = s.tracks.length;
    progressLabel = 'looking for covers already on the files';
    notifyListeners();

    final found = await scanAlbumArt(
      s.tracks,
      reuse: index,
      onProgress: (done, total) {
        progressDone = done;
        progressTotal = total;
        if (done % 25 == 0 || done == total) notifyListeners();
      },
    );

    artScan = found;

    // Remembered, so a second art pass over an untouched collection
    // reads nothing — the expensive part of this pass is opening every
    // embedded image to find out whether there is one.
    final current = index;
    if (current != null) {
      index = TrackIndex(
        rootPath: current.rootPath,
        scannedAt: current.scannedAt,
        tracks: current.tracks,
        embeddedArt: found.embeddedArt,
        artChecked: found.checked,
        folderImages: found.folderImages,
        scanSeconds: current.scanSeconds,
      );
      await (await IndexStore.open()).save(index!);
    }
    albums = planArtwork(
      s.tracks,
      embeddedArt: found.embeddedArt,
      folderImages: found.folderImages,
    );
    _rebuildArtPlan();
    artBusy = false;
    notifyListeners();
  }

  void _rebuildArtPlan() {
    artPlan = artActions(
      albums,
      existingCovers: artScan?.existingCovers ?? const {},
    );
  }

  /// Asks MusicBrainz and the Cover Art Archive about the albums nothing
  /// local could settle.
  ///
  /// Only ever called from an explicit confirmation. One request per
  /// second, which is their published limit — see `cover_art.dart`.
  Future<String> fetchMissingArt({bool Function()? isCancelled}) async {
    final todo = albumsNeedingLookup;
    if (todo.isEmpty || artBusy) return 'Nothing to look up.';

    artBusy = true;
    artLookupRan = true;
    progressDone = 0;
    progressTotal = todo.length;
    progressLabel = 'asking the Cover Art Archive';
    notifyListeners();

    final dir = await getApplicationDocumentsDirectory();
    final harvest = CoverArtHarvest(
      lookup: CoverArtLookup(fetch: httpFetcher()),
      cacheDir: Directory('${dir.path}/cover-art-cache'),
    );

    final result = await harvest.run(
      todo,
      onProgress: (done, total, what) {
        progressDone = done;
        progressTotal = total;
        progressLabel = what;
        notifyListeners();
      },
      isCancelled: isCancelled,
    );

    // The downloaded albums replace their needs-a-lookup versions; every
    // other album is left exactly as it was.
    final byKey = {
      for (final a in result.filled) '${a.artist}|${a.album}': a,
    };
    albums = [
      for (final a in albums) byKey['${a.artist}|${a.album}'] ?? a,
    ];
    artNotes = result.notes;
    _rebuildArtPlan();

    artBusy = false;
    notifyListeners();

    final bits = <String>['Found ${result.filled.length} of ${todo.length}'];
    if (result.stoppedEarly) {
      bits.add('stopped early — worth trying again later');
    }
    return bits.join(' · ');
  }

  /// Writes the approved art. Its own run, with its own result.
  Future<void> applyArt() async {
    final toRun = approvedArt;
    if (toRun.isEmpty || artBusy) return;

    artBusy = true;
    progressDone = 0;
    progressTotal = toRun.actionCount;
    progressLabel = 'writing covers';
    notifyListeners();

    final j = await _openJournal();
    lastArtResult = await applyPlan(
      toRun,
      j,
      onProgress: (done, total) {
        progressDone = done;
        progressTotal = total;
        if (done % 10 == 0 || done == total) notifyListeners();
      },
    );

    // Art changes tags and adds files; it moves nothing, so the file
    // scan's paths are all still good. What is out of date is the art
    // scan — the files that just got covers no longer need them. The
    // plan is dropped so it cannot be run twice; the scan is kept, for
    // the bug report.
    artPlan = const [];
    artIsStale = true;

    // Same as a sorting run: the journal says what was written, so the
    // index follows along and the next art pass only reads the files
    // that actually changed.
    await _absorb(toRun, j);

    artBusy = false;
    await refreshUndoState();
    notifyListeners();
  }

  // ------------------------------------------------------------ apply

  Future<void> applyApproved() async {
    final toRun = approved;
    if (toRun.isEmpty) return;

    stage = Stage.applying;
    progressDone = 0;
    progressTotal = toRun.actionCount;
    notifyListeners();

    final j = await _openJournal();
    lastResult = await applyPlan(
      toRun,
      j,
      onProgress: (done, total) {
        progressDone = done;
        progressTotal = total;
        if (done % 10 == 0 || done == total) notifyListeners();
      },
    );

    // The index is brought along rather than thrown away.
    //
    // This is what the whole index exists for. A run used to invalidate
    // every path in the scan, which meant a full rescan before anything
    // else could be done — and if that rescan was skipped, the next
    // apply failed on every file, which is exactly the "0 applied, 249
    // failed" this app spent four versions on. The journal already says
    // precisely what happened, so the index can simply be edited to
    // match.
    await _absorb(toRun, j);

    stage = Stage.done;
    await refreshUndoState();
    notifyListeners();
  }

  /// Folds what a run did into the index, the scan and the plan.
  ///
  /// Driven by the journal, not the plan: the plan is what was intended
  /// and the journal is what happened. On a collection this size those
  /// differ often enough that reading the plan would quietly put the
  /// index out of step with the disk, which is worse than having no
  /// index at all.
  Future<void> _absorb(Plan applied, Journal journal) async {
    final current = index;
    if (current == null) {
      // No index to update, so fall back to the old behaviour: the scan
      // describes paths that may have moved.
      scanIsStale = true;
      return;
    }

    final entries = await journal.read();
    // Only this run's entries. The journal accumulates across runs, and
    // replaying an earlier run's moves over an index that already
    // reflects them would move tracks to paths nothing is on.
    final mine = _entriesFor(entries, applied);

    var next = current.afterJournal(mine, applied: applied);

    // Re-read the stamps of everything that was touched, so those files
    // are not needlessly re-read on the next scan. Cheap: a `stat` each,
    // against 3.7ms each to read them again.
    final store = await IndexStore.open();
    final touched = <String>{
      for (final e in mine)
        if (e.succeeded) e.targetPath ?? e.path,
    };
    next = next.withFreshStamps(store.stampsFor(touched));

    index = next;
    scan = ScanResult(
      tracks: next.tracks,
      skipped: scan?.skipped ?? const [],
      elapsed: scan?.elapsed ?? Duration.zero,
    );
    duplicates = findDuplicates(next.tracks);
    rejected.clear();
    _rebuildPlan();

    // Not stale: the scan now describes the collection as it actually
    // is. A failed action left its file exactly where it was — the
    // applier guarantees that, including undoing a copy whose original
    // could not be removed — so a failure does not make this untrue.
    scanIsStale = false;

    await store.save(next);
  }

  /// The journal entries belonging to one run.
  ///
  /// Matched on kind and path against the plan that was applied. Not by
  /// timestamp: two runs a second apart would be indistinguishable, and
  /// a device whose clock moved would make the whole idea unsound.
  static List<JournalEntry> _entriesFor(
    List<JournalEntry> entries,
    Plan applied,
  ) {
    final wanted = {
      for (final a in applied.all) '${a.kind.name}:${a.path}',
    };
    // From the end backwards, keeping only the most recent entry for
    // each action, then back into order. A path acted on in an earlier
    // run as well would otherwise be replayed twice.
    final seen = <String>{};
    final out = <JournalEntry>[];
    for (var i = entries.length - 1; i >= 0; i--) {
      final e = entries[i];
      final key = '${e.kind.name}:${e.path}';
      if (!wanted.contains(key)) continue;
      if (!seen.add(key)) continue;
      out.add(e);
    }
    return out.reversed.toList();
  }

  Future<void> undoEverything() async {
    stage = Stage.applying;
    progressDone = 0;
    progressLabel = 'undoing';
    notifyListeners();

    final j = await _openJournal();
    lastResult = await undo(
      j,
      onProgress: (done, total) {
        progressDone = done;
        progressTotal = total;
        if (done % 10 == 0 || done == total) notifyListeners();
      },
    );

    // Undo puts files back where they came from, which the index cannot
    // be edited into describing — it would have to be reversed, and the
    // journal has just been cleared. One rescan, which is now cheap for
    // everything undo did not touch.
    scanIsStale = true;
    stage = Stage.done;
    await refreshUndoState();
    notifyListeners();
  }

  // ---------------------------------------------------- save and reload

  /// Writes the scan to a file that can be loaded back.
  Future<String?> saveSession(String path) async {
    final s = scan;
    final root = rootPath;
    if (s == null || root == null) return null;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeSession(Session(
      rootPath: root,
      tracks: s.tracks,
      scannedAt: DateTime.now(),
      scanSeconds: s.elapsed.inSeconds,
    )));
    lastSavedPath = path;
    notifyListeners();
    return path;
  }

  /// Writes the readable report.
  Future<String?> saveReport(String path) async {
    final s = scan;
    final p = plan;
    final root = rootPath;
    if (s == null || p == null || root == null) return null;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(writeReport(
      rootPath: root,
      scan: s,
      duplicates: duplicates,
      plan: p,
    ));
    lastSavedPath = path;
    notifyListeners();
    return path;
  }

  /// Loads a scan saved earlier, skipping the three-minute reread.
  ///
  /// The loaded paths describe the collection as it was when saved, so
  /// the scan is treated as unverified: a "check files still exist" pass
  /// is offered before anything can be applied.
  Future<String> loadSession(String path) async {
    final result = decodeSession(await File(path).readAsString());
    rootPath = result.session.rootPath;
    scan = ScanResult(
      tracks: result.session.tracks,
      skipped: const [],
      elapsed: Duration(seconds: result.session.scanSeconds),
    );
    duplicates = findDuplicates(result.session.tracks);
    // The loaded scan doubles as an index, because a saved session
    // carries each file's size and modification time. That makes the
    // rescan below cheap for everything that has not changed — which is
    // strictly better than the old "check the paths still exist" pass,
    // since it is nearly as fast and actually re-reads what moved.
    index = TrackIndex(
      rootPath: result.session.rootPath,
      scannedAt: result.session.scannedAt,
      tracks: result.session.tracks,
      scanSeconds: result.session.scanSeconds,
    );
    lastReuse = null;
    _rebuildPlan();
    lastResult = null;
    // Loaded from disk, so the files may have moved since. Rescanning
    // is now the cheap option rather than the expensive one.
    scanIsStale = true;
    stage = Stage.scanned;
    notifyListeners();

    final bits = <String>['Loaded ${result.session.tracks.length} files'];
    if (result.skipped > 0) bits.add('${result.skipped} rows unreadable');
    if (result.fromNewerBuild) bits.add('saved by a newer build');
    return bits.join(' · ');
  }

  /// Checks the scanned paths are still where they were.
  ///
  /// Far cheaper than a rescan — one stat per file rather than reading
  /// headers — and it is what clears the stale flag after a load or a
  /// run, so the next apply cannot fail en masse on paths that moved.
  Future<int> verifyPaths() async {
    final s = scan;
    if (s == null) return 0;
    stage = Stage.scanning;
    progressLabel = 'checking files are still there';
    progressDone = 0;
    notifyListeners();

    final alive = <Track>[];
    var missing = 0;
    for (final t in s.tracks) {
      if (File(t.path).existsSync()) {
        alive.add(t);
      } else {
        missing++;
      }
      progressDone++;
      if (progressDone % 200 == 0) notifyListeners();
    }

    scan = ScanResult(
        tracks: alive, skipped: s.skipped, elapsed: s.elapsed);
    duplicates = findDuplicates(alive);
    _rebuildPlan();
    scanIsStale = false;
    stage = Stage.scanned;
    notifyListeners();
    return missing;
  }

  // --------------------------------------------------------- reporting

  Map<QualityBand, int> get qualityCounts {
    final out = <QualityBand, int>{};
    for (final t in scan?.tracks ?? const <Track>[]) {
      final b = t.band;
      if (b != null) out[b] = (out[b] ?? 0) + 1;
    }
    return out;
  }

  DuplicateSummary get duplicateSummary => summariseDuplicates(duplicates);

  /// The copyable bug report.
  String bugReport() => buildBugReport(
        appVersion: kAppVersion,
        platform: '${Platform.operatingSystem} '
            '${Platform.operatingSystemVersion}',
        rootPath: rootPath,
        scan: scan,
        plan: plan,
        duplicates: duplicates,
        lastRun: lastResult == null
            ? null
            : ApplyOutcome(
                succeeded: lastResult!.succeeded,
                failed: lastResult!.failed,
                errors: lastResult!.errors,
              ),
        scanIsStale: scanIsStale,
        now: DateTime.now(),
        art: _artReport(),
        index: _indexReport(),
      );

  IndexReport? _indexReport() {
    final current = index;
    if (current == null) return null;
    final reuse = lastReuse;
    return IndexReport(
      tracks: current.tracks.length,
      reused: reuse?.reused ?? 0,
      read: reuse?.read ?? 0,
      vanished: reuse?.vanished ?? 0,
      scannedAt: current.scannedAt,
      artChecked: current.artChecked.length,
      withArt: current.embeddedArt.length,
      withoutStamp:
          current.tracks.where((t) => t.modifiedMs == 0).length,
    );
  }

  /// Null when the art pass has never been run, so the report says
  /// nothing rather than reporting zeros that look like findings.
  ArtReport? _artReport() {
    final summary = artSummary;
    final found = artScan;
    if (summary == null || found == null) return null;
    return ArtReport(
      summary: summary,
      plannedCovers: artPlan
          .where((a) => a.kind == ActionKind.writeCover)
          .length,
      plannedEmbeds:
          artPlan.where((a) => a.kind == ActionKind.embedArt).length,
      lookupRan: artLookupRan,
      unreadable: found.unreadable,
      notes: artNotes,
      lastRun: lastArtResult == null
          ? null
          : ApplyOutcome(
              succeeded: lastArtResult!.succeeded,
              failed: lastArtResult!.failed,
              errors: lastArtResult!.errors,
            ),
    );
  }

  /// Writes the report beside the collection, for when it is too long to
  /// paste comfortably.
  Future<String?> saveBugReport() async {
    final root = rootPath;
    if (root == null) return null;
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(RegExp(r'[:-]'), '');
    final path = '$root/mp3sorter-bug-$stamp.txt';
    try {
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(bugReport());
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Files in one quality band, worst first, for the browse screen.
  ///
  /// Computed on demand rather than stored: it is a sort of a list
  /// already in memory, and the whole point of this change is that
  /// quality is derived, not kept.
  List<Track> tracksInBand(QualityBand band) {
    final out = [
      for (final t in scan?.tracks ?? const <Track>[])
        if (t.band == band) t,
    ]..sort((a, b) {
        final byRate = (a.bitrateKbps ?? 0).compareTo(b.bitrateKbps ?? 0);
        return byRate != 0 ? byRate : a.path.compareTo(b.path);
      });
    return out;
  }
}
