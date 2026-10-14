/// Saving a scan so it can be reloaded, and writing a readable report.
///
/// Scanning 3,000 files off an SD card takes nearly three minutes on a
/// phone. Without this, every change of mind about a setting costs
/// another three minutes, so in practice settings do not get changed and
/// the plan does not get examined properly.
///
/// Two formats, because they answer different questions:
///
///  * **`.json`** reloads into the app exactly as scanned. The whole
///    point is not to read the files again.
///  * **`.txt`** is for reading on a bigger screen — the proposed moves,
///    the duplicate groups, the artist merges, in full. A 5,000-row list
///    is not reviewable on a phone, and pretending otherwise is how a
///    plan gets approved unread.
library;

import 'dart:convert';

import 'bitrate.dart';
import 'duplicates.dart';
import 'plan.dart';
import 'scanner.dart';
import 'track.dart';

/// Bumped only when an older build could not read a newer file
/// correctly. Adding a field does not count — unknown keys are ignored,
/// which is what makes the format additive.
const int kSessionVersion = 1;

const String kSessionMagic = 'mp3sorter.scan';

/// A saved scan, plus where it came from.
class Session {
  const Session({
    required this.rootPath,
    required this.tracks,
    required this.scannedAt,
    this.scanSeconds = 0,
  });

  final String rootPath;
  final List<Track> tracks;
  final DateTime scannedAt;
  final int scanSeconds;
}

String encodeSession(Session session) => const JsonEncoder.withIndent('  ')
    .convert({
      'format': kSessionMagic,
      'version': kSessionVersion,
      'root': session.rootPath,
      'scannedAt': session.scannedAt.toIso8601String(),
      'scanSeconds': session.scanSeconds,
      'tracks': [for (final t in session.tracks) t.toJson()],
    });

/// What came back from reading a file, including what did not survive.
class SessionReadResult {
  const SessionReadResult({
    required this.session,
    required this.skipped,
    required this.fromNewerBuild,
  });

  final Session session;

  /// Rows that could not be read. Reported rather than silently dropped.
  final int skipped;

  final bool fromNewerBuild;
}

class SessionFormatException implements Exception {
  const SessionFormatException(this.message);
  final String message;
  @override
  String toString() => 'SessionFormatException: $message';
}

/// Reads a saved scan.
///
/// Throws only when the file is not one of ours. A malformed track is
/// counted and skipped, the same rule the rest of the app follows: one
/// bad row should cost that row.
SessionReadResult decodeSession(String source) {
  final Object? root;
  try {
    root = jsonDecode(source);
  } on FormatException {
    throw const SessionFormatException('not a JSON file');
  }
  if (root is! Map) throw const SessionFormatException('not a saved scan');
  if (root['format'] != kSessionMagic) {
    throw const SessionFormatException('not an MP3 Sorter scan');
  }

  final tracks = <Track>[];
  var skipped = 0;
  for (final raw in (root['tracks'] as List? ?? const [])) {
    if (raw is! Map) {
      skipped++;
      continue;
    }
    final t = Track.fromJson(raw.cast<String, Object?>());
    if (t == null) {
      skipped++;
    } else {
      tracks.add(t);
    }
  }

  return SessionReadResult(
    session: Session(
      rootPath: root['root'] as String? ?? '',
      tracks: tracks,
      scannedAt:
          DateTime.tryParse('${root['scannedAt']}') ?? DateTime.now(),
      scanSeconds: (root['scanSeconds'] as num?)?.toInt() ?? 0,
    ),
    skipped: skipped,
    fromNewerBuild: (root['version'] as num? ?? 0) > kSessionVersion,
  );
}

/// A readable report of a scan and the plan built from it.
///
/// Plain text on purpose: it opens anywhere, it diffs, and it can be read
/// on a laptop while the phone holds the files.
String writeReport({
  required String rootPath,
  required ScanResult scan,
  required List<DuplicateGroup> duplicates,
  required Plan plan,
}) {
  final b = StringBuffer();
  void line([String s = '']) => b.writeln(s);
  void rule(String title) {
    line();
    line('── $title ${'─' * (60 - title.length).clamp(0, 60)}');
    line();
  }

  line('MP3 Sorter report');
  line('root     $rootPath');
  line('scanned  ${scan.tracks.length} files in ${scan.elapsed.inSeconds}s');
  line('written  ${DateTime.now().toIso8601String()}');

  rule('quality');
  final counts = <QualityBand, int>{};
  for (final t in scan.tracks) {
    final q = t.band;
    if (q != null) counts[q] = (counts[q] ?? 0) + 1;
  }
  for (final band in QualityBand.values) {
    line('  ${band.name.padRight(12)} ${counts[band] ?? 0}');
  }
  final unreadable = scan.tracks.where((t) => !t.isReadable).toList();
  line('  unreadable   ${unreadable.length}');
  for (final t in unreadable.take(20)) {
    line('      ${t.path}  — ${t.readError}');
  }

  rule('artist spellings that would be merged');
  if (plan.artistMerges.isEmpty) {
    line('  none');
  } else {
    for (final e in plan.artistMerges.entries) {
      line('  ${e.key}');
      for (final v in e.value) {
        line('      ← $v');
      }
    }
  }

  rule('duplicates');
  final summary = summariseDuplicates(duplicates);
  line('  ${summary.groups} groups, ${summary.removable} removable, '
      '${(summary.reclaimableBytes / 1073741824).toStringAsFixed(2)} GB');
  for (final g in duplicates) {
    line();
    line('  [${g.kind.name}]');
    line('    keep  ${g.keep.path}  (${g.keep.bitrateKbps}k)');
    for (final d in g.discard) {
      line('    drop  ${d.path}  (${d.bitrateKbps}k)');
    }
  }

  rule('moves (${plan.moves.length})');
  for (final m in plan.moves) {
    line('  ${m.path}');
    line('    -> ${m.targetPath}   [${m.reason}]');
  }

  rule('tag writes (${plan.retags.length})');
  for (final r in plan.retags) {
    line('  ${r.path}');
    line('    ${r.reason}');
  }

  rule('left alone (${plan.unsortable.length})');
  for (final t in plan.unsortable) {
    line('  ${t.path}  — ${t.readError ?? "no usable artist"}');
  }

  return b.toString();
}
