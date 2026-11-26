/// What the app remembers between runs: progress through each folder, and
/// the undo journal.
///
/// Plain JSON files in the app's own storage, each written through a temp
/// file and a rename so a crash mid-save keeps the previous version.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tags.dart';

/// 64-bit FNV-1a, for turning a folder path into a file name.
String fnv1a(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = h * 0x100000001b3; // wraps at 64 bits on the Dart VM
  }
  return BigInt.from(h).toUnsigned(64).toRadixString(16).padLeft(16, "0");
}

Future<void> writeJsonAtomic(File file, Object json) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(json), flush: true);
  await tmp.rename(file.path);
}

Future<Object?> readJson(File file) async {
  try {
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString());
  } catch (_) {
    return null;
  }
}

/// Where a track stands in its folder's session.
enum TrackStatus { pending, accepted, skipped, failed }

/// Progress through one folder, so closing the app halfway through four
/// hundred tracks does not mean starting again.
class Session {
  Session(this.root, this._file, [Map<String, TrackStatus>? status])
      : status = status ?? {};

  final String root;
  final File? _file;
  final Map<String, TrackStatus> status;

  TrackStatus of(String path) => status[path] ?? TrackStatus.pending;
  bool isPending(String path) => of(path) == TrackStatus.pending;

  void set(String path, TrackStatus s) {
    if (s == TrackStatus.pending) {
      status.remove(path);
    } else {
      status[path] = s;
    }
  }

  static Future<Session> load(Directory appDir, String root) async {
    final file = File('${appDir.path}/sessions/${fnv1a(root)}.json');
    final raw = await readJson(file);
    final map = <String, TrackStatus>{};
    if (raw is Map && raw['status'] is Map) {
      (raw['status'] as Map).forEach((k, v) {
        final s = TrackStatus.values.where((e) => e.name == v).firstOrNull;
        if (k is String && s != null) map[k] = s;
      });
    }
    return Session(root, file, map);
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    await writeJsonAtomic(f, {
      'root': root,
      'status': {for (final e in status.entries) e.key: e.value.name},
    });
  }
}

/// One undoable write.
class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.group,
    required this.path,
    required this.before,
    required this.coversBefore,
    required this.at,
    this.blockFile,
    this.noop = false,
  });

  final String id;

  /// The track was accepted as it was, so nothing was written. Kept so that
  /// undoing a batch also puts these back in the queue.
  final bool noop;

  /// Entries written together (a batch) share a group and are undone
  /// together.
  final String group;
  final String path;
  final TagSet before;
  final int coversBefore;
  final DateTime at;

  /// For MP3s: where the original tag bytes are kept.
  final String? blockFile;

  Map<String, Object?> toJson() => {
        'id': id,
        'group': group,
        'path': path,
        'before': before.toJson(),
        'coversBefore': coversBefore,
        'at': at.toIso8601String(),
        'blockFile': blockFile,
        if (noop) 'noop': true,
      };

  static JournalEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return JournalEntry(
        id: j['id'] as String,
        group: j['group'] as String,
        path: j['path'] as String,
        before: TagSet.fromJson(Map<String, Object?>.from(j['before'] as Map)),
        coversBefore: (j['coversBefore'] as num).toInt(),
        at: DateTime.parse(j['at'] as String),
        blockFile: j['blockFile'] as String?,
        noop: j['noop'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The undo history, newest last.
///
/// Original MP3 tag blocks are stored as separate files (a tag with a cover
/// can be a megabyte; it does not belong inside a JSON list). Kept to the
/// last [maxEntries] writes; older blocks are deleted with their entries.
class Journal {
  Journal(this._dir, {this.maxEntries = 2000});

  final Directory? _dir;
  final int maxEntries;
  final List<JournalEntry> entries = [];
  int _counter = 0;

  File? get _index => _dir == null ? null : File('${_dir.path}/journal.json');

  static Future<Journal> load(Directory appDir) async {
    final j = Journal(Directory('${appDir.path}/undo'));
    final raw = await readJson(j._index!);
    if (raw is List) {
      for (final e in raw) {
        final entry = JournalEntry.fromJson(e);
        if (entry != null) j.entries.add(entry);
      }
    }
    return j;
  }

  String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_counter++}';

  Future<JournalEntry> record({
    required String group,
    required String path,
    required TagSet before,
    required int coversBefore,
    Uint8List? originalTagBlock,
    bool noop = false,
  }) async {
    final id = newId();
    String? blockFile;
    final dir = _dir;
    if (originalTagBlock != null && dir != null) {
      await dir.create(recursive: true);
      blockFile = '${dir.path}/$id.id3';
      await File(blockFile).writeAsBytes(originalTagBlock, flush: true);
    }
    final entry = JournalEntry(
      id: id,
      group: group,
      path: path,
      before: before,
      coversBefore: coversBefore,
      at: DateTime.now(),
      blockFile: blockFile,
      noop: noop,
    );
    entries.add(entry);
    while (entries.length > maxEntries) {
      final old = entries.removeAt(0);
      await _deleteBlock(old);
    }
    await save();
    return entry;
  }

  /// The most recent group, newest entry first — the order to undo in.
  List<JournalEntry> lastGroup() {
    if (entries.isEmpty) return const [];
    final g = entries.last.group;
    return entries.reversed.takeWhile((e) => e.group == g).toList();
  }

  Future<Uint8List?> blockOf(JournalEntry e) async {
    final f = e.blockFile;
    if (f == null) return null;
    try {
      return await File(f).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(JournalEntry e) async {
    entries.removeWhere((x) => x.id == e.id);
    await _deleteBlock(e);
    await save();
  }

  Future<void> _deleteBlock(JournalEntry e) async {
    final f = e.blockFile;
    if (f == null) return;
    try {
      await File(f).delete();
    } catch (_) {}
  }

  Future<void> save() async {
    final f = _index;
    if (f == null) return;
    await writeJsonAtomic(f, [for (final e in entries) e.toJson()]);
  }
}

/// Small settings: recent folders, the Last.fm key, subfolder scanning.
class Settings {
  Settings(this._file);
  final File? _file;

  List<String> recentFolders = [];
  String lastFmKey = '';
  bool includeSubfolders = true;
  double volume = 0.5;

  static Future<Settings> load(Directory appDir) async {
    final s = Settings(File('${appDir.path}/settings.json'));
    final raw = await readJson(s._file!);
    if (raw is Map) {
      s.recentFolders =
          (raw['recentFolders'] as List?)?.whereType<String>().toList() ?? [];
      s.lastFmKey = raw['lastFmKey'] as String? ?? '';
      s.includeSubfolders = raw['includeSubfolders'] as bool? ?? true;
      s.volume = (raw['volume'] as num?)?.toDouble() ?? 0.5;
    }
    return s;
  }

  void touchFolder(String path) {
    recentFolders.remove(path);
    recentFolders.insert(0, path);
    if (recentFolders.length > 8) recentFolders = recentFolders.sublist(0, 8);
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    await writeJsonAtomic(f, {
      'recentFolders': recentFolders,
      'lastFmKey': lastFmKey,
      'includeSubfolders': includeSubfolders,
      'volume': volume,
    });
  }
}
