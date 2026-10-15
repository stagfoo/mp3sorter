/// A report you can copy out and send.
///
/// Added because debugging this from screenshots was costing a round
/// trip per bug, and the screenshots truncate exactly the part that
/// matters — "…and 112 more" hid the pattern that identified the cause
/// both times.
///
/// Pure: it turns the app's state into text and knows nothing about
/// clipboards or files, so what it produces can be asserted in a test.
library;

import 'bitrate.dart';
import 'duplicates.dart';
import 'plan.dart';
import 'scanner.dart';

/// Everything worth knowing about a run that went wrong.
///
/// Deliberately includes **every** failure rather than the first few.
/// The pattern across all of them is the diagnosis: 120 failures that
/// all said "already exists" pointed at the planner, and seeing only
/// eight of them would not have.
String buildBugReport({
  required String appVersion,
  required String platform,
  required String? rootPath,
  required ScanResult? scan,
  required Plan? plan,
  required List<DuplicateGroup> duplicates,
  required ApplyOutcome? lastRun,
  required bool scanIsStale,
  required DateTime now,
}) {
  final b = StringBuffer();
  void line([String s = '']) => b.writeln(s);

  line('MP3 Sorter bug report');
  line('=====================');
  line('version   $appVersion');
  line('platform  $platform');
  line('at        ${now.toIso8601String()}');
  line();

  line('-- collection --');
  line('root      ${rootPath ?? "(none chosen)"}');
  // Outside the scan block: whether the app believes its paths are
  // current is a fact about the run either way, and leaving it out when
  // there is no scan makes the report's shape vary for no reason.
  line('stale     $scanIsStale');
  if (scan == null) {
    line('scan      (none)');
  } else {
    line('files     ${scan.tracks.length}');
    line('scan time ${scan.elapsed.inSeconds}s');
    final unreadable = scan.tracks.where((t) => !t.isReadable).length;
    line('unreadable $unreadable');

    final bands = <QualityBand, int>{};
    for (final t in scan.tracks) {
      final q = t.band;
      if (q != null) bands[q] = (bands[q] ?? 0) + 1;
    }
    line('quality   ${[
      for (final q in QualityBand.values) '${q.name}=${bands[q] ?? 0}'
    ].join(' ')}');
  }
  line();

  line('-- plan --');
  if (plan == null) {
    line('(none)');
  } else {
    line('moves      ${plan.moves.length}');
    line('retags     ${plan.retags.length}');
    line('trashes    ${plan.trashes.length}');
    line('unsortable ${plan.unsortable.length}');
    line('stationary ${plan.stationaryPaths.length}');
    line('blocked    ${plan.blockedMoves.length}  (rename cycles)');
    for (final m in plan.blockedMoves.take(10)) {
      line('   ${m.path}');
      line('     -> ${m.targetPath}');
    }
    final problems = validatePlan(plan);
    line('problems   ${problems.length}');
    for (final p in problems) {
      line('   ${p.message}  (${p.paths.length})');
      for (final path in p.paths.take(5)) {
        line('      $path');
      }
    }
  }
  line();

  line('-- duplicates --');
  final summary = summariseDuplicates(duplicates);
  line('groups ${summary.groups}  removable ${summary.removable}  '
      '${(summary.reclaimableBytes / 1073741824).toStringAsFixed(2)} GB');
  line();

  line('-- last run --');
  if (lastRun == null) {
    line('(none)');
  } else {
    line('applied ${lastRun.succeeded}  failed ${lastRun.failed}');
    if (lastRun.errors.isNotEmpty) {
      // All of them. The screenshots that reported the last two bugs
      // both cut off at eight, and the pattern across the rest was the
      // thing that identified the cause.
      line();
      line('failures (${lastRun.errors.length}):');
      for (final e in lastRun.errors) {
        line('  $e');
      }
    }
  }

  return b.toString();
}

/// The parts of an apply result the report needs, without this file
/// having to depend on the applier.
class ApplyOutcome {
  const ApplyOutcome({
    required this.succeeded,
    required this.failed,
    required this.errors,
  });

  final int succeeded;
  final int failed;
  final List<String> errors;
}

/// Groups identical-shaped failures so a thousand of one problem reads
/// as one problem.
///
/// Paths differ on every line, so the distinguishing part is what comes
/// after the colon. Collapsing on that turns "120 failures" into "120
/// files, one cause", which is the first thing anyone needs to know.
Map<String, int> summariseErrors(List<String> errors) {
  final counts = <String, int>{};
  for (final e in errors) {
    final colon = e.indexOf(': ');
    final reason = colon < 0 ? e : e.substring(colon + 2);
    // Paths inside the reason ("already exists at /a/b/c") would make
    // every line unique again, so a trailing path is trimmed off.
    final trimmed = reason.replaceAll(RegExp(r'\s*/\S+'), ' …');
    counts[trimmed] = (counts[trimmed] ?? 0) + 1;
  }
  return Map.fromEntries(
    counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
  );
}
