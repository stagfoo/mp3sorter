import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/track.dart';

void main(List<String> a) async {
  final scan = await scanDirectory(Directory(a.first));
  var withArt = 0, withoutArt = 0, failed = 0;
  final albumHasArt = <String, bool>{};
  final albumFiles = <String, int>{};

  for (final t in scan.tracks) {
    try {
      final m = readMetadata(File(t.path), getImage: true);
      final has = m.pictures.isNotEmpty;
      has ? withArt++ : withoutArt++;
      final key = '${t.artist ?? "?"}|${t.album ?? inferNames(t).title}';
      albumFiles[key] = (albumFiles[key] ?? 0) + 1;
      albumHasArt[key] = (albumHasArt[key] ?? false) || has;
    } catch (_) { failed++; }
  }

  // Art files sitting next to the music.
  final dirs = <String>{for (final t in scan.tracks) File(t.path).parent.path};
  var dirsWithImage = 0;
  for (final d in dirs) {
    final has = Directory(d).listSync().whereType<File>().any((f) {
      final n = f.path.toLowerCase();
      return n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png');
    });
    if (has) dirsWithImage++;
  }

  final rescuable = albumHasArt.entries
      .where((e) => e.value)
      .fold<int>(0, (s, e) => s + (albumFiles[e.key] ?? 0));

  print('files                        ${scan.tracks.length}');
  print('  with embedded art          $withArt');
  print('  without                    $withoutArt');
  print('  unreadable                 $failed');
  print('album groups                 ${albumFiles.length}');
  print('  at least one file with art ${albumHasArt.values.where((v) => v).length}');
  print('  files in those groups      $rescuable  <- fillable offline');
  print('folders holding music        ${dirs.length}');
  print('  with a jpg/png beside it   $dirsWithImage');
}
