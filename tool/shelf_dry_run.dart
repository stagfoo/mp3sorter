/// How the review crate would look for a real collection: how many
/// artists, how crowded the busiest dials get, and how much ends up on
/// the nameless shelf. Writes nothing.
///
///   dart run tool/shelf_dry_run.dart <dir>
import 'dart:io';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/shelf.dart';

void main(List<String> args) async {
  final root = Directory(args.first);
  final scan = await scanDirectory(root);
  final plan = buildPlan(
      scan.tracks,
      PlanOptions(root: '${root.path}/_sorted', sourceRoot: root.path));

  for (final (label, actions) in [
    ('moves', plan.moves),
    ('tags', plan.retags),
  ]) {
    final sw = Stopwatch()..start();
    final shelves = shelve(actions);
    sw.stop();
    final albums = shelves.fold(0, (n, s) => n + s.albums.length);
    final nameless = shelves.where((s) => s.name == null).toList();
    print('── $label: ${actions.length} actions ──');
    print('  ${shelves.length} artists, $albums records, '
        'shelved in ${sw.elapsedMilliseconds}ms');
    print('  no artist: ${nameless.isEmpty ? 0 : nameless.single.actions.length}');
    final counts = <int, int>{};
    for (final s in shelves) {
      final n = s.albums.length;
      final b = n <= 1 ? 1 : n <= 4 ? 4 : n <= 10 ? 10 : n <= 24 ? 24 : 99;
      counts[b] = (counts[b] ?? 0) + 1;
    }
    print('  records per artist: 1:${counts[1] ?? 0}  2-4:${counts[4] ?? 0}  '
        '5-10:${counts[10] ?? 0}  11-24 (two rings):${counts[24] ?? 0}  '
        '25+ (grid):${counts[99] ?? 0}');
    final busiest = [...shelves]
      ..sort((a, b) => b.albums.length.compareTo(a.albums.length));
    for (final s in busiest.take(6)) {
      print('    ${s.albums.length.toString().padLeft(3)} records  '
          '${s.actions.length.toString().padLeft(4)} files  ${s.name}');
    }
    final band = shelves.where((s) =>
        (s.name ?? '').toLowerCase().contains('band of skulls'));
    for (final s in band) {
      print('  ${s.name}: ${[for (final a in s.albums) "${a.title} (${a.actions.length})"].join(", ")}');
    }
  }
}
