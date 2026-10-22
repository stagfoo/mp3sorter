/// Cover pictures for the review, read on demand.
///
/// Only for looking at. Nothing here is written anywhere, and nothing
/// reaches the network — an album with no local art gets a sleeve
/// generated from its name, which is still something a person can tell
/// apart from its neighbours at a glance.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'artwork.dart';
import 'cover_art.dart';

/// Covers already found, most recently used last.
///
/// Bounded because a collection has hundreds of albums, a cover is
/// often half a megabyte, and the crate is meant to be flicked through
/// from A to Z without the app being killed for it.
class SleeveArt {
  SleeveArt({this.capacity = 120});

  final int capacity;
  final _cache = <String, Future<Uint8List?>>{};

  /// The cover for a group of files, keyed by [key]. Tries the first
  /// few files' embedded art, then an image in their folder.
  Future<Uint8List?> coverFor(String key, List<String> paths) {
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final fresh = _cache[key] = _find(paths.take(4).toList());
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return fresh;
  }

  static Future<Uint8List?> _find(List<String> paths) async {
    // Off the UI thread: a cover read parses the whole ID3 tag, and the
    // crate asks for several while it is being scrolled.
    try {
      return await Isolate.run(() => _findSync(paths));
    } catch (_) {
      return null;
    }
  }
}

Uint8List? _findSync(List<String> paths) {
  for (final path in paths) {
    if (!path.toLowerCase().endsWith('.mp3')) continue;
    try {
      final meta = readMetadata(File(path), getImage: true);
      if (meta.pictures.isEmpty) continue;
      final picture = meta.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => meta.pictures.first,
      );
      if (sniffImageType(picture.bytes) != null) return picture.bytes;
    } catch (_) {
      // An unreadable tag is not worth a broken sleeve. Try the next.
    }
  }

  final folders = {
    for (final p in paths)
      if (p.contains('/')) p.substring(0, p.lastIndexOf('/')),
  };
  for (final folder in folders) {
    try {
      final images = Directory(folder)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => f.path);
      final cover = pickFolderCover(images);
      if (cover == null) continue;
      final bytes = File(cover).readAsBytesSync();
      if (sniffImageType(bytes) != null) return bytes;
    } catch (_) {
      // A folder that cannot be listed has no cover we can show.
    }
  }
  return null;
}
