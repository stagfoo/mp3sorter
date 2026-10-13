/// Runs the full pipeline over a real collection and prints what it
/// *would* do. Writes nothing. The honest check that the pure logic
/// survives contact with 5,000 real files.
///
///   dart run tool/dry_run.dart <dir>
import 'dart:io';
import 'package:mp3sorter/bitrate.dart';
import 'package:mp3sorter/duplicates.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/track.dart';

void main(List<String> args) async {
  final root = Directory(args.first);
  stdout.write('scanning... ');
  final scan = await scanDirectory(root);
  print('${scan.tracks.length} files in ${scan.elapsed.inSeconds}s');

  final bands = <QualityBand, int>{};
  var unreadable = 0, untagged = 0, vbr = 0;
  for (final t in scan.tracks) {
    if (!t.isReadable) { unreadable++; continue; }
    if (!t.hasUsableTags) untagged++;
    if (t.isVbr) vbr++;
    final b = t.band;
    if (b != null) bands[b] = (bands[b] ?? 0) + 1;
  }

  print('\n── quality ──');
  for (final b in QualityBand.values) {
    print('  ${b.name.padRight(12)} ${bands[b] ?? 0}');
  }
  print('  vbr          $vbr');
  print('  unreadable   $unreadable');
  print('  no usable tags $untagged');

  print('\n── artist spellings that would be merged ──');
  final canon = canonicalArtists(scan.tracks);
  final merges = <String, List<String>>{};
  canon.forEach((v, c) { if (v != c) merges.putIfAbsent(c, () => []).add(v); });
  print('  ${merges.length} groups');
  var shown = 0;
  for (final e in merges.entries) {
    if (shown++ >= 10) break;
    print('    ${e.key}  ←  ${e.value.join(", ")}');
  }

  print('\n── duplicates ──');
  final dupes = findDuplicates(scan.tracks);
  final s = summariseDuplicates(dupes);
  print('  ${s.groups} groups, ${s.removable} removable, '
      '${(s.reclaimableBytes / 1073741824).toStringAsFixed(2)} GB');
  for (final kind in DuplicateKind.values) {
    print('    ${kind.name.padRight(14)} ${dupes.where((g) => g.kind == kind).length}');
  }
  for (final g in dupes.take(5)) {
    print('    [${g.kind.name}] keep ${g.keep.path.split('/').last} '
        '(${g.keep.bitrateKbps}k) drop ${g.discard.length}');
  }

  print('\n── plan ──');
  final plan = buildPlan(scan.tracks,
      PlanOptions(root: '${root.path}/_sorted', removeDuplicates: false));
  print('  moves      ${plan.moves.length}');
  print('  retags     ${plan.retags.length}');
  print('  unsortable ${plan.unsortable.length}');
  final problems = validatePlan(plan);
  print('  problems   ${problems.length}');
  for (final pr in problems.take(5)) {
    print('    !! ${pr.message}: ${pr.paths.take(2).join(", ")}');
  }
  print('\n  sample moves:');
  for (final m in plan.moves.take(6)) {
    print('    ${m.path.split('/').last}');
    print('      -> ${m.targetPath!.replaceFirst(root.path, "")}  [${m.reason}]');
  }
}
