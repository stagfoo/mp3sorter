/// Where the index lives between launches.
///
/// One file per collection, so a card and an internal folder each keep
/// their own and scanning one does not throw away the other's work.
///
/// Everything here is I/O and failure handling. The rules about what an
/// index *means* are in `track_index.dart`, which is pure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'track_index.dart';

class IndexStore {
  IndexStore._(this._dir);

  final Directory _dir;
  static IndexStore? _cached;

  static Future<IndexStore> open() async {
    if (_cached != null) return _cached!;
    final docs = await getApplicationDocumentsDirectory();
    return _cached = IndexStore._(Directory('${docs.path}/mp3sorter-index'));
  }

  /// The index file for one collection.
  ///
  /// Named after a hash of the path rather than the path itself: a real
  /// root is `/storage/1FA4-15A1/Music`, and turning that into a
  /// filename means either a name with slashes in it or a mangling that
  /// two different folders could collide on. A hash cannot collide in
  /// any way that matters and is the same length every time.
  File fileFor(String rootPath) {
    final digest = sha1.convert(utf8.encode(_tidy(rootPath)));
    return File('${_dir.path}/$digest.json');
  }

  static String _tidy(String path) {
    var out = path.trim();
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// Reads the index for a collection, or null.
  ///
  /// Null for every kind of problem — missing, unreadable, corrupt,
  /// written by a newer build. It is a cache; the only cost of not
  /// having it is one slow scan, and that is always better than acting
  /// on something that might be wrong.
  Future<TrackIndex?> load(String rootPath) async {
    final file = fileFor(rootPath);
    if (!file.existsSync()) return null;
    try {
      return decodeIndex(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Writes the index, atomically.
  ///
  /// Through a temporary file and a rename, because the alternative is a
  /// half-written index after a crash or a card pulled mid-write — and
  /// a half-written index that still parses is far worse than none,
  /// since it would be trusted. A rename either happens or does not.
  ///
  /// Returns false rather than throwing. Saving the index is an
  /// optimisation; a scan that worked must not be reported as failed
  /// because the cache could not be written.
  Future<bool> save(TrackIndex index) async {
    try {
      await _dir.create(recursive: true);
      final target = fileFor(index.rootPath);
      final temp = File('${target.path}.writing');
      await temp.writeAsString(encodeIndex(index), flush: true);
      await temp.rename(target.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> forget(String rootPath) async {
    try {
      final f = fileFor(rootPath);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // Nothing useful to do. A stale index that cannot be deleted is
      // still only ever trusted as far as each file's stamp allows.
    }
  }

  /// Reads the current size and modification time of each path.
  ///
  /// The companion to [TrackIndex.afterJournal], which clears the stamp
  /// of every file a run touched. Re-reading those stamps costs
  /// microseconds each and saves re-reading the files themselves at
  /// 3.7ms each on the next scan.
  ///
  /// A path that cannot be `stat`ed is left out, so its stamp stays
  /// cleared and it gets read again — the safe direction.
  Map<String, (int, int)> stampsFor(Iterable<String> paths) {
    final out = <String, (int, int)>{};
    for (final path in paths) {
      try {
        final stat = File(path).statSync();
        if (stat.type == FileSystemEntityType.notFound) continue;
        out[path] = (stat.size, stat.modified.millisecondsSinceEpoch);
      } catch (_) {
        continue;
      }
    }
    return out;
  }
}
