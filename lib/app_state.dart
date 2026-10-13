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
import 'scanner.dart';
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

  Journal? _journal;

  Future<Journal> _openJournal() async {
    if (_journal != null) return _journal!;
    final dir = await getApplicationDocumentsDirectory();
    return _journal = Journal(File('${dir.path}/mp3sorter-journal.jsonl'));
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
        tagQuality: options.tagQuality,
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

    stage = Stage.done;
    await refreshUndoState();
    notifyListeners();
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
}
