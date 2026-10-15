/// The art pass against the real collection, writing nothing.
///
/// Exists for the same reason `dry_run.dart` does: the planner's rules
/// are tested on hand-built cases, and the collection is the only thing
/// that tells you whether those rules describe it.
library;

import 'dart:io';

import 'package:mp3sorter/artwork.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/scanner.dart';

void main(List<String> args) async {
  final root = args.first;
  stdout.writeln('scanning $root …');
  final scan = await scanDirectory(Directory(root));
  stdout.writeln('${scan.tracks.length} files in ${scan.elapsed.inSeconds}s');

  stdout.writeln('reading covers …');
  final art = await scanAlbumArt(
    scan.tracks,
    onProgress: (done, total) {
      if (done % 500 == 0) stdout.writeln('  $done / $total');
    },
  );
  stdout.writeln('cover scan took ${art.elapsed.inSeconds}s');

  final albums = planArtwork(
    scan.tracks,
    embeddedArt: art.embeddedArt,
    folderImages: art.folderImages,
  );
  final summary = summariseArtwork(albums);
  final actions = artActions(albums, existingCovers: art.existingCovers);

  stdout.writeln('');
  stdout.writeln('files with art            ${art.embeddedArt.length}');
  stdout.writeln('unreadable                ${art.unreadable.length}');
  stdout.writeln('folders with an image     ${art.folderImages.length}');
  stdout.writeln('albums                    ${summary.albums}');
  stdout.writeln('  complete                ${summary.complete}');
  stdout.writeln('  from a sibling          ${summary.fromSibling}');
  stdout.writeln('  from a folder image     ${summary.fromFolder}');
  stdout.writeln('  need a lookup           ${summary.needLookup}');
  stdout.writeln('files missing art         ${summary.filesMissing}');
  stdout.writeln('  fixable offline         ${summary.filesFixableOffline}');
  stdout.writeln('');
  stdout.writeln('planned cover files       '
      '${actions.where((a) => a.kind == ActionKind.writeCover).length}');
  stdout.writeln('planned embeds            '
      '${actions.where((a) => a.kind == ActionKind.embedArt).length}');

  // The invariants worth asserting against five thousand real files.
  final plan = Plan(
    moves: const [],
    retags: const [],
    trashes: const [],
    art: actions,
    artistMerges: const {},
    unsortable: const [],
  );
  final problems = validatePlan(plan);
  stdout.writeln('');
  stdout.writeln(problems.isEmpty
      ? 'plan validates'
      : 'PROBLEMS: ${problems.map((p) => p.message).join("; ")}');

  // No action may target a file that already has what it would write.
  final badEmbeds = [
    for (final a in actions)
      if (a.kind == ActionKind.embedArt && art.embeddedArt.containsKey(a.path))
        a.path,
  ];
  stdout.writeln(badEmbeds.isEmpty
      ? 'no embed targets a file that already has art'
      : 'BAD: ${badEmbeds.length} embeds target files that already have art');

  final badCovers = [
    for (final a in actions)
      if (a.kind == ActionKind.writeCover &&
          art.existingCovers.contains(a.path.toLowerCase()))
        a.path,
  ];
  stdout.writeln(badCovers.isEmpty
      ? 'no cover would be written over an existing one'
      : 'BAD: ${badCovers.length} covers would overwrite');

  // Every source must be readable and must actually hold art.
  final badSources = [
    for (final a in actions)
      if (a.artFrom == null || !File(a.artFrom!).existsSync()) a.path,
  ];
  stdout.writeln(badSources.isEmpty
      ? 'every action has a source that exists'
      : 'BAD: ${badSources.length} actions have no usable source');

  final sharedFolders = albums.where((a) => a.folderIsShared).length;
  stdout.writeln('albums in a shared folder '
      '$sharedFolders (no cover file written for these)');

  stdout.writeln('');
  stdout.writeln('a few albums that would be filled:');
  for (final a in albums.where((a) => !a.isSatisfied && !a.needsNetwork).take(8)) {
    stdout.writeln('  ${a.artist} — ${a.album} '
        '(${a.tracksMissingArt.length} files, ${a.source.name}) '
        '-> ${a.folder}/${a.coverFileName}');
  }
  stdout.writeln('');
  stdout.writeln('a few that would need a lookup:');
  for (final a in albums.where((a) => a.needsNetwork).take(8)) {
    stdout.writeln('  ${a.artist} — ${a.album} '
        '(${a.tracksMissingArt.length} files)');
  }
}
