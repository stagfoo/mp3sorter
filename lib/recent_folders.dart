/// Folders scanned before, so getting back in is one tap.
///
/// The list logic is pure and the storage is a thin wrapper, so the rules
/// that actually matter — ordering, deduplication, what happens when a
/// path is gone — are testable without a device.
///
/// The decision worth stating: **an entry whose folder is not currently
/// there is kept, not dropped.** This collection lives on a removable SD
/// card at `/storage/1FA4-15A1/`, and that path simply does not exist
/// while the card is out. Pruning on "does it exist" would quietly empty
/// the list every time the card was unmounted, which is precisely when
/// remembering would have been useful.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A folder scanned at some point, and what was found in it.
class RecentFolder {
  const RecentFolder({
    required this.path,
    required this.lastUsed,
    this.fileCount = 0,
  });

  final String path;
  final DateTime lastUsed;

  /// How many audio files were found last time. Shown because it is the
  /// quickest way to tell two folders apart when both are called "Music".
  final int fileCount;

  /// The last path segment — what the folder is called.
  String get name {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// Enough of the path above it to tell two same-named folders apart.
  ///
  /// `/storage/1FA4-15A1/Music` and `/storage/emulated/0/Music` are both
  /// "Music", and showing only the name would make the list a guess.
  String get parentLabel {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return path;
    return parts.sublist(0, parts.length - 1).join('/');
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'lastUsed': lastUsed.toIso8601String(),
        'fileCount': fileCount,
      };

  static RecentFolder? fromJson(Map<String, Object?> j) {
    final path = j['path'];
    if (path is! String || path.isEmpty) return null;
    return RecentFolder(
      path: path,
      lastUsed: DateTime.tryParse('${j['lastUsed']}') ?? DateTime(2000),
      fileCount: (j['fileCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// How many to keep. Enough to cover the folders anyone actually revisits,
/// short enough to stay a glance rather than a list to read.
const int kMaxRecentFolders = 8;

/// Adds a folder to the list, newest first.
///
/// Re-scanning a folder already in the list moves it to the top and
/// updates its count rather than adding a second entry — otherwise the
/// list fills with one folder.
List<RecentFolder> remember(
  List<RecentFolder> existing,
  RecentFolder entry, {
  int cap = kMaxRecentFolders,
}) {
  final out = <RecentFolder>[
    entry,
    for (final e in existing)
      // Trailing slashes make the same folder look like two.
      if (_normalise(e.path) != _normalise(entry.path)) e,
  ];
  out.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
  return out.take(cap).toList();
}

List<RecentFolder> forget(List<RecentFolder> existing, String path) => [
      for (final e in existing)
        if (_normalise(e.path) != _normalise(path)) e,
    ];

String _normalise(String path) {
  var p = path.trim();
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

String encodeRecents(List<RecentFolder> folders) =>
    jsonEncode([for (final f in folders) f.toJson()]);

/// Reads the list, keeping whatever is usable.
///
/// A malformed entry costs that entry. Returning an empty list because
/// one row was bad would lose every folder someone had scanned.
List<RecentFolder> decodeRecents(String source) {
  final Object? root;
  try {
    root = jsonDecode(source);
  } on FormatException {
    return const [];
  }
  if (root is! List) return const [];
  final out = <RecentFolder>[];
  for (final raw in root) {
    if (raw is! Map) continue;
    final f = RecentFolder.fromJson(raw.cast<String, Object?>());
    if (f != null) out.add(f);
  }
  out.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
  return out;
}

/// Where the list lives between launches.
class RecentFoldersStore {
  RecentFoldersStore._(this._file);

  final File _file;
  static RecentFoldersStore? _cached;

  static Future<RecentFoldersStore> open() async {
    if (_cached != null) return _cached!;
    final dir = await getApplicationDocumentsDirectory();
    return _cached = RecentFoldersStore._(
        File('${dir.path}/mp3sorter-recent-folders.json'));
  }

  Future<List<RecentFolder>> load() async {
    if (!_file.existsSync()) return const [];
    try {
      return decodeRecents(await _file.readAsString());
    } catch (_) {
      // An unreadable list is not worth failing the app over; it is a
      // convenience, and the folder picker still works.
      return const [];
    }
  }

  Future<List<RecentFolder>> add(String path, int fileCount) async {
    final next = remember(
      await load(),
      RecentFolder(
          path: path, lastUsed: DateTime.now(), fileCount: fileCount),
    );
    await _write(next);
    return next;
  }

  Future<List<RecentFolder>> remove(String path) async {
    final next = forget(await load(), path);
    await _write(next);
    return next;
  }

  Future<void> _write(List<RecentFolder> folders) async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(encodeRecents(folders));
    } catch (_) {
      // Same reasoning: losing the convenience beats failing the scan
      // that just succeeded.
    }
  }
}
