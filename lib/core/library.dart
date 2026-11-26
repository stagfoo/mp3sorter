/// Building the queue from a folder, finding a folder's cover image, and
/// deciding what a batch applies to.
library;

import 'dart:io';
import 'dart:typed_data';

import 'net.dart' show sniffImageType;
import 'tag_io.dart';

/// Splits a path into (directory, file name).
(String, String) splitPath(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  if (i < 0) return ('', path);
  return (path.substring(0, i), path.substring(i + 1));
}

String dirOf(String path) => splitPath(path).$1;

final RegExp _digits = RegExp(r'\d+|\D+');

/// "2 Song" before "10 Song". Plain string order puts 10 before 2, which
/// shuffles every album with more than nine tracks.
int naturalCompare(String a, String b) {
  final pa = _digits.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final pb = _digits.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// Orders tracks folder by folder, naturally within each — so a folder's
/// tracks sit next to each other in the queue, which is what makes "apply
/// this album to the rest of the folder" a matter of the next few cards.
List<String> orderTracks(Iterable<String> paths) {
  final list = paths.toList();
  list.sort((a, b) {
    final (da, fa) = splitPath(a);
    final (db, fb) = splitPath(b);
    final c = naturalCompare(da, db);
    return c != 0 ? c : naturalCompare(fa, fb);
  });
  return list;
}

/// Whether a path should be skipped while scanning: hidden folders (Android's
/// `.thumbnails`, `.trash`), and this app's own temporary files.
bool isIgnoredPath(String relative) {
  for (final part in relative.split(RegExp(r'[\\/]'))) {
    if (part.startsWith('.')) return true;
  }
  return relative.contains('.mp3sorter-tmp');
}

/// Every audio file under [root], in queue order.
Future<List<String>> scanFolder(String root, {bool recursive = true}) async {
  final out = <String>[];
  final dir = Directory(root);
  await for (final e in dir.list(recursive: recursive, followLinks: false)
      .handleError((_) {})) {
    if (e is! File) continue;
    final rel = e.path.length > root.length ? e.path.substring(root.length + 1) : e.path;
    if (isIgnoredPath(rel)) continue;
    if (isAudioFile(e.path)) out.add(e.path);
  }
  return orderTracks(out);
}

/// File names that are a folder's cover, best first.
const List<String> _coverNames = [
  'cover',
  'folder',
  'front',
  'album',
  'albumart',
  'albumartlarge',
  'albumartsmall',
];

/// Picks the image in a folder most likely to be its front cover.
///
/// Returns null when there is no obvious one — a folder of ten screenshots
/// is not a folder with a cover, and guessing wrong would put the same
/// random picture on every track.
String? pickFolderCover(Iterable<String> imagePaths) {
  final images = imagePaths
      .where((p) => const {'.jpg', '.jpeg', '.png'}.contains(extensionOf(p)))
      .toList();
  if (images.isEmpty) return null;
  for (final name in _coverNames) {
    for (final p in images) {
      final (_, file) = splitPath(p);
      final stem = file.substring(0, file.lastIndexOf('.')).toLowerCase();
      if (stem == name) return p;
    }
  }
  for (final p in images) {
    final (_, file) = splitPath(p);
    if (RegExp(r'cover|front|folder', caseSensitive: false).hasMatch(file)) {
      return p;
    }
  }
  return images.length == 1 ? images.single : null;
}

/// The cover image sitting next to a track, if there is one.
///
/// This is where a lot of "missing" covers really are: a sorting app moved
/// the songs into new folders and left `folder.jpg` behind, or the player
/// only ever showed the folder image and the songs never had one embedded.
Future<CoverImage?> folderCover(String dir) async {
  try {
    final images = <String>[];
    await for (final e in Directory(dir).list(followLinks: false)) {
      if (e is File) images.add(e.path);
    }
    final pick = pickFolderCover(images);
    if (pick == null) return null;
    final bytes = await File(pick).readAsBytes();
    final type = sniffImageType(bytes);
    if (type == null) return null;
    return CoverImage(Uint8List.fromList(bytes), type);
  } catch (_) {
    return null;
  }
}

/// The tracks a swipe-up batch applies to: the ones after [index] in the
/// queue that are in the same folder as it and still waiting.
List<int> batchTargets(
  List<String> queue,
  int index,
  bool Function(String path) isPending,
) {
  if (index < 0 || index >= queue.length) return const [];
  final dir = dirOf(queue[index]);
  final out = <int>[];
  for (var i = index + 1; i < queue.length; i++) {
    if (dirOf(queue[i]) != dir) break; // the queue is grouped by folder
    if (isPending(queue[i])) out.add(i);
  }
  return out;
}
