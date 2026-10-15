/// Does reuse actually pay, and does it give the same answer?
///
/// The second question is the one that matters. A rescan that is fast
/// and subtly different from a full one is worse than a slow one.
library;

import 'dart:io';

import 'package:mp3sorter/artwork.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/scanner.dart';
import 'package:mp3sorter/track_index.dart';

void main(List<String> args) async {
  final root = args.first;

  stdout.writeln('== cold scan (no index) ==');
  final cold = await scanDirectory(Directory(root));
  stdout.writeln('${cold.tracks.length} files in ${cold.elapsed.inMilliseconds}ms'
      ' · ${cold.reuse.describe()}');

  final index = TrackIndex(
    rootPath: root,
    scannedAt: DateTime.now(),
    tracks: cold.tracks,
    scanSeconds: cold.elapsed.inSeconds,
  );

  // Round-tripped through the file format, because that is how it will
  // actually arrive — a bug in the encoding would otherwise be invisible
  // to a benchmark that kept the object in memory.
  final encoded = encodeIndex(index);
  stdout.writeln('index size ${(encoded.length / 1024).round()} KB');
  final reloaded = decodeIndex(encoded)!;
  stdout.writeln('reloaded ${reloaded.tracks.length} tracks');

  stdout.writeln('');
  stdout.writeln('== warm scan (with index) ==');
  final warm = await scanDirectory(Directory(root), reuse: reloaded);
  stdout.writeln('${warm.tracks.length} files in ${warm.elapsed.inMilliseconds}ms'
      ' · ${warm.reuse.describe()}');
  final speedup = cold.elapsed.inMilliseconds / warm.elapsed.inMilliseconds;
  stdout.writeln('${speedup.toStringAsFixed(1)}x faster');

  stdout.writeln('');
  stdout.writeln('== same answer? ==');
  var differences = 0;
  final coldByPath = {for (final t in cold.tracks) t.path: t};
  for (final w in warm.tracks) {
    final c = coldByPath[w.path];
    if (c == null) {
      differences++;
      continue;
    }
    if (c.artist != w.artist ||
        c.title != w.title ||
        c.album != w.album ||
        c.bitrateKbps != w.bitrateKbps ||
        c.sampleRate != w.sampleRate ||
        c.channels != w.channels ||
        c.duration != w.duration ||
        c.audioFingerprint != w.audioFingerprint ||
        c.sizeBytes != w.sizeBytes ||
        c.readError != w.readError) {
      differences++;
      if (differences <= 5) stdout.writeln('  differs: ${w.path}');
    }
  }
  stdout.writeln(differences == 0
      ? 'every track identical'
      : 'DIFFERENT on $differences tracks');

  final coldPlan = buildPlan(cold.tracks,
      PlanOptions(root: '$root/_sorted', sourceRoot: root));
  final warmPlan = buildPlan(warm.tracks,
      PlanOptions(root: '$root/_sorted', sourceRoot: root));
  stdout.writeln(
      coldPlan.moves.length == warmPlan.moves.length &&
              coldPlan.retags.length == warmPlan.retags.length
          ? 'identical plan (${warmPlan.moves.length} moves, '
              '${warmPlan.retags.length} retags)'
          : 'DIFFERENT PLAN: cold ${coldPlan.moves.length}/'
              '${coldPlan.retags.length} vs warm ${warmPlan.moves.length}/'
              '${warmPlan.retags.length}');

  stdout.writeln('');
  stdout.writeln('== art pass ==');
  final coldArt = await scanAlbumArt(cold.tracks);
  stdout.writeln('cold ${coldArt.elapsed.inMilliseconds}ms, '
      '${coldArt.embeddedArt.length} with art, '
      '${coldArt.reusedCount} reused');

  final withArt = TrackIndex(
    rootPath: root,
    scannedAt: DateTime.now(),
    tracks: warm.tracks,
    embeddedArt: coldArt.embeddedArt,
    artChecked: coldArt.checked,
    folderImages: coldArt.folderImages,
  );
  final warmArt =
      await scanAlbumArt(warm.tracks, reuse: decodeIndex(encodeIndex(withArt))!);
  stdout.writeln('warm ${warmArt.elapsed.inMilliseconds}ms, '
      '${warmArt.embeddedArt.length} with art, '
      '${warmArt.reusedCount} reused');

  final sameArt = coldArt.embeddedArt.length == warmArt.embeddedArt.length &&
      coldArt.embeddedArt.entries
          .every((e) => warmArt.embeddedArt[e.key] == e.value);
  stdout.writeln(sameArt ? 'art identical' : 'ART DIFFERS');

  final coldAlbums = planArtwork(cold.tracks,
      embeddedArt: coldArt.embeddedArt, folderImages: coldArt.folderImages);
  final warmAlbums = planArtwork(warm.tracks,
      embeddedArt: warmArt.embeddedArt, folderImages: warmArt.folderImages);
  stdout.writeln(artActions(coldAlbums).length == artActions(warmAlbums).length
      ? 'identical art plan (${artActions(warmAlbums).length} actions)'
      : 'ART PLAN DIFFERS');

  exit(0);
}
