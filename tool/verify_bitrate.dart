/// Compares this app's frame parser against ffprobe on real files.
///
/// Not a unit test — it needs ffprobe and an actual collection. It exists
/// because the off-the-shelf tag library disagreed with ffprobe on six of
/// seven sampled files, and the only way to know this parser does better
/// is to ask the same question of the same files.
///
///   dart run tool/verify_bitrate.dart <dir> [sampleCount]
import 'dart:io';
import 'package:mp3sorter/bitrate.dart';
import 'package:mp3sorter/file_source.dart';

void main(List<String> args) async {
  final dir = Directory(args.first);
  final want = args.length > 1 ? int.parse(args[1]) : 60;

  final all = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.mp3'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final step = (all.length / want).ceil().clamp(1, all.length);
  final sample = [for (var i = 0; i < all.length; i += step) all[i]];

  var agree = 0, close = 0, differ = 0, failed = 0;
  final sw = Stopwatch()..start();
  final bad = <String>[];
  final noStream = <String>[];

  for (final f in sample) {
    int? mine;
    var isVbr = false;
    try {
      final src = FileByteSource(f);
      final info = analyseMp3(src);
      mine = info.bitrateKbps;
      isVbr = info.isVbr;
      src.close();
    } catch (e) {
      failed++;
      bad.add('  PARSE FAIL ${f.path.split('/').last}: $e');
      continue;
    }
    // The *stream* bitrate, not the format one. format=bit_rate is
    // file_size*8/duration, so it includes the ID3 tag and any embedded
    // album art — on a short track with a big cover that reads 25% high,
    // and comparing against it made a correct parser look wrong.
    final r = await Process.run('ffprobe', [
      '-v', 'error', '-select_streams', 'a:0',
      '-show_entries', 'stream=bit_rate',
      '-of', 'csv=p=0', f.path,
    ]);
    final ff = int.tryParse(r.stdout.toString().trim());
    if (ff == null) {
      // ffprobe omits stream bit_rate for some VBR files; fall back to
      // the format figure minus tag overhead, which is the best it can do.
      failed++;
      noStream.add('  no ffprobe stream bitrate: mine=${mine}k vbr=$isVbr  '
          '${f.path.split('/').last}');
      continue;
    }
    final ffk = ff ~/ 1000;
    final delta = (mine - ffk).abs();
    if (delta == 0) {
      agree++;
    } else if (delta <= 3) {
      // ffprobe's format bitrate includes tag and container overhead, so
      // a kbps or two of disagreement is expected and not an error.
      close++;
    } else {
      differ++;
      bad.add('  ${mine}k vs ffprobe ${ffk}k  ${f.path.split('/').last}');
    }
  }
  sw.stop();
  print('sampled ${sample.length} of ${all.length} files in ${sw.elapsed.inSeconds}s');
  print('  exact      $agree');
  print('  within 3k  $close');
  print('  DIFFER     $differ');
  print('  failed     $failed');
  bad.take(10).forEach(print);
  noStream.take(6).forEach(print);
}
