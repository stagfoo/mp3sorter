/// Carrying out a plan, and being able to take it back.
///
/// Every applied action is appended to a journal *before* the next one
/// runs, so an interrupted run — a crash, a dead battery, a drive
/// unplugged mid-rename — leaves a journal describing exactly what had
/// happened up to that point. Undo reads it backwards.
///
/// Nothing is ever unlinked. A removed duplicate is moved into a trash
/// directory, which makes "undo a deletion" the same operation as "undo
/// a move" and means a wrong call costs a drag back rather than a file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'plan.dart';

/// One thing that was done, recorded so it can be undone.
class JournalEntry {
  const JournalEntry({
    required this.kind,
    required this.path,
    required this.at,
    this.targetPath,
    this.previousArtist,
    this.previousTitle,
    this.previousGenres,
    this.error,
  });

  final ActionKind kind;

  /// Where the file was before this action.
  final String path;

  /// Where it ended up, for a move or a trash.
  final String? targetPath;

  /// What the tags were before a retag. Undo writes these back — which
  /// is why they are captured even when the field was empty: "it had no
  /// artist" is a fact that has to survive too.
  final String? previousArtist;
  final String? previousTitle;
  final List<String>? previousGenres;

  final DateTime at;

  /// Set when the action failed. Failures are journalled as well as
  /// successes: a run that half-worked needs a record of which half.
  final String? error;

  bool get succeeded => error == null;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'path': path,
        if (targetPath != null) 'targetPath': targetPath,
        if (previousArtist != null) 'previousArtist': previousArtist,
        if (previousTitle != null) 'previousTitle': previousTitle,
        if (previousGenres != null) 'previousGenres': previousGenres,
        'at': at.toIso8601String(),
        if (error != null) 'error': error,
      };

  static JournalEntry? fromJson(Map<String, Object?> j) {
    final kindName = j['kind'];
    final kind = ActionKind.values
        .where((k) => k.name == kindName)
        .cast<ActionKind?>()
        .firstWhere((_) => true, orElse: () => null);
    // An entry written by a future version with an action this build does
    // not know is skipped, not fatal — the same rule the rest of the app
    // follows for unknown data.
    if (kind == null || j['path'] is! String) return null;
    return JournalEntry(
      kind: kind,
      path: j['path']! as String,
      targetPath: j['targetPath'] as String?,
      previousArtist: j['previousArtist'] as String?,
      previousTitle: j['previousTitle'] as String?,
      previousGenres: (j['previousGenres'] as List?)?.cast<String>(),
      at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
      error: j['error'] as String?,
    );
  }
}

/// An append-only log of what was done.
///
/// JSON Lines rather than one JSON document: a half-written array is
/// unparseable and loses the whole run, whereas a half-written final line
/// costs one entry and the rest still reads.
class Journal {
  Journal(this.file);

  final File file;

  Future<void> append(JournalEntry entry) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(entry.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<List<JournalEntry>> read() async {
    if (!file.existsSync()) return const [];
    final out = <JournalEntry>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final e = JournalEntry.fromJson(decoded.cast<String, Object?>());
        if (e != null) out.add(e);
      } catch (_) {
        // A truncated last line from an interrupted run. Everything
        // before it is still good, which is the point of the format.
        continue;
      }
    }
    return out;
  }

  Future<void> clear() async {
    if (file.existsSync()) await file.delete();
  }
}

/// How a run went.
class ApplyResult {
  const ApplyResult({
    required this.succeeded,
    required this.failed,
    required this.errors,
  });

  final int succeeded;
  final int failed;

  /// One line per failure, naming the file. A run that reports "12
  /// failed" without saying which is a run you cannot act on.
  final List<String> errors;

  bool get allSucceeded => failed == 0;
}

/// Applies a plan, journalling as it goes.
///
/// [onProgress] is called after each action so a long run can show where
/// it is. A failure does not stop the run: on a collection this size one
/// unwritable file should not abandon four thousand good changes, and the
/// journal records which ones did not take.
Future<ApplyResult> applyPlan(
  Plan plan,
  Journal journal, {
  void Function(int done, int total)? onProgress,
}) async {
  // Trash first, then tags, then moves. Order matters: retagging a file
  // and then moving it means the journal's retag entry names a path that
  // no longer exists, and undo would fail to find it.
  final actions = [...plan.trashes, ...plan.retags, ...plan.moves];

  var ok = 0, bad = 0;
  final errors = <String>[];

  for (var i = 0; i < actions.length; i++) {
    final action = actions[i];
    try {
      final entry = await _applyOne(action);
      await journal.append(entry);
      if (entry.succeeded) {
        ok++;
      } else {
        bad++;
        errors.add('${action.path}: ${entry.error}');
      }
    } catch (e) {
      bad++;
      errors.add('${action.path}: $e');
      await journal.append(JournalEntry(
        kind: action.kind,
        path: action.path,
        targetPath: action.targetPath,
        at: DateTime.now(),
        error: '$e',
      ));
    }
    onProgress?.call(i + 1, actions.length);
  }

  return ApplyResult(succeeded: ok, failed: bad, errors: errors);
}

Future<JournalEntry> _applyOne(PlannedAction action) async {
  final now = DateTime.now();
  final source = File(action.path);

  if (!source.existsSync()) {
    return JournalEntry(
      kind: action.kind,
      path: action.path,
      targetPath: action.targetPath,
      at: now,
      // Not a crash: the collection can change between the scan and the
      // apply, and a file that has already gone is a fact to record.
      error: 'file no longer exists',
    );
  }

  switch (action.kind) {
    case ActionKind.retag:
      String? wasArtist;
      String? wasTitle;
      List<String>? wasGenres;
      try {
        final before = readMetadata(source, getImage: false);
        wasArtist = before.artist;
        wasTitle = before.title;
        wasGenres = List<String>.from(before.genres);
      } catch (_) {
        // Unreadable tags are not a reason to refuse to write new ones,
        // but undo cannot restore what could not be read — recorded as
        // nulls rather than guessed.
      }

      updateMetadata(source, (m) {
        if (action.artist != null) m.setArtist(action.artist);
        if (action.title != null) m.setTitle(action.title);
        if (action.genres != null) m.setGenres(action.genres!);
      });

      return JournalEntry(
        kind: ActionKind.retag,
        path: action.path,
        at: now,
        previousArtist: wasArtist,
        previousTitle: wasTitle,
        previousGenres: wasGenres,
      );

    case ActionKind.move:
    case ActionKind.trash:
      final target = action.targetPath!;
      // Refusing rather than overwriting. The planner already
      // disambiguates, so arriving here means something changed on disk
      // since the scan — and silently replacing a file is the one
      // mistake with no undo.
      if (File(target).existsSync()) {
        return JournalEntry(
          kind: action.kind,
          path: action.path,
          targetPath: target,
          at: now,
          error: 'something already exists at $target',
        );
      }
      await Directory(File(target).parent.path).create(recursive: true);
      await _moveFile(source, target);
      return JournalEntry(
        kind: action.kind,
        path: action.path,
        targetPath: target,
        at: now,
      );
  }
}

/// Moves a file, falling back to copy-and-delete across filesystems.
///
/// `rename` fails with EXDEV between devices, which is exactly the case
/// here: a phone moving a file from an SD card to internal storage, or a
/// desktop between two drives. The copy is verified by length before the
/// original goes, so a half-copy never costs the source.
Future<void> _moveFile(File source, String target) async {
  try {
    await source.rename(target);
    return;
  } on FileSystemException {
    // Cross-device. Fall through to copy and delete.
  }
  final copied = await source.copy(target);
  if (await copied.length() != await source.length()) {
    await copied.delete();
    throw FileSystemException('copy was incomplete', target);
  }
  await source.delete();
}

/// Reverses a journal, newest first.
///
/// Backwards because the actions were ordered — trash, then retag, then
/// move — and undoing them forwards would try to retag a file at a path
/// it has since left.
Future<ApplyResult> undo(Journal journal,
    {void Function(int done, int total)? onProgress}) async {
  final entries = (await journal.read()).where((e) => e.succeeded).toList();
  var ok = 0, bad = 0;
  final errors = <String>[];

  for (var i = entries.length - 1; i >= 0; i--) {
    final e = entries[i];
    try {
      switch (e.kind) {
        case ActionKind.move:
        case ActionKind.trash:
          final moved = File(e.targetPath!);
          if (!moved.existsSync()) {
            throw FileSystemException('not where it was put', e.targetPath);
          }
          if (File(e.path).existsSync()) {
            throw FileSystemException('something is back at', e.path);
          }
          await Directory(File(e.path).parent.path).create(recursive: true);
          await _moveFile(moved, e.path);

        case ActionKind.retag:
          final f = File(e.path);
          if (!f.existsSync()) {
            throw FileSystemException('file is gone', e.path);
          }
          updateMetadata(f, (m) {
            m.setArtist(e.previousArtist);
            m.setTitle(e.previousTitle);
            if (e.previousGenres != null) m.setGenres(e.previousGenres!);
          });
      }
      ok++;
    } catch (err) {
      bad++;
      errors.add('${e.path}: $err');
    }
    onProgress?.call(entries.length - i, entries.length);
  }

  // Only once everything that could be reversed has been. Clearing a
  // journal with failures still in it would strand those files with no
  // record of where they came from.
  if (bad == 0) await journal.clear();

  return ApplyResult(succeeded: ok, failed: bad, errors: errors);
}
