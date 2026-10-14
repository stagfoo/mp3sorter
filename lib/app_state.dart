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
import 'bitrate.dart';
import 'duplicates.dart';
import 'plan.dart';
import 'recent_folders.dart';
import 'scanner.dart';
import 'session_file.dart';
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
    notifyListeners();
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

    final result = await scanDirectory(
      Directory(path),
      onProgress: (done, file) {
        progressDone = done;
        progressLabel = file.split('/').last;
        // Not on every file: 5,000 notifications would spend more time
        // rebuilding the screen than reading the files.
        if (done % 25 == 0) notifyListeners();
      },
    );

    scan = result;
    scanIsStale = false;
    lastResult = null;

    // Recorded after the scan rather than when the folder is picked, so
    // the remembered file count is a real one and a cancelled or failed
    // scan does not leave a misleading entry.
    final store = await RecentFoldersStore.open();
    recentFolders = await store.add(path, result.tracks.length);

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
        renameFiles: options.renameFiles,
        writeTags: options.writeTags,
        cleanQualityTags: options.cleanQualityTags,
        standardiseArtists: options.standardiseArtists,
        removeDuplicates: options.removeDuplicates,
      ),
    );
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

    // Anything that moved a file invalidates every path in the scan.
    if ((lastResult?.succeeded ?? 0) > 0 &&
        (toRun.moves.isNotEmpty || toRun.trashes.isNotEmpty)) {
      scanIsStale = true;
    }

    stage = Stage.done;
    await refreshUndoState();
    notifyListeners();
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

    // Undo moves files back, so the scan is stale either way.
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
    _rebuildPlan();
    lastResult = null;
    // Loaded from disk, so the files may have moved since. Verifying is
    // one tap and far cheaper than a full rescan.
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
