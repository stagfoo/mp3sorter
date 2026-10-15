/// Why files are not being filed. Reports the shape of the names that
/// defeat inferNames, which is the thing to fix.
import 'dart:io';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/track.dart';

void main(List<String> args) async {
  final scan = await scanDirectory(Directory(args.first));
  var tagged = 0, fromName = 0, noArtist = 0;
  final samples = <String>[];
  for (final t in scan.tracks) {
    final n = inferNames(t);
    if (!n.isComplete) {
      noArtist++;
      if (samples.length < 14) samples.add(t.path.split('/').last);
    } else if (n.fromTags) {
      tagged++;
    } else {
      fromName++;
    }
  }
  print('files ${scan.tracks.length}');
  print('  filed from tags      $tagged');
  print('  filed from filename  $fromName');
  print('  cannot be filed      $noArtist');
  print('\nnames that defeat the parser:');
  samples.forEach((s) => print('  $s'));

  // How many of the unfilable ones carry an "artist-title" with no
  // spaces around the dash — a shape the splitter does not know.
  final bare = RegExp(r'^[^/]*?[a-z0-9]-[a-z0-9]');
  var bareDash = 0;
  for (final t in scan.tracks) {
    if (inferNames(t).isComplete) continue;
    if (bare.hasMatch(t.stem.toLowerCase())) bareDash++;
  }
  print('\nof those, "artist-title" with no spaces: $bareDash');
}
