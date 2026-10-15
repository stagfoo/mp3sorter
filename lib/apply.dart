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
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'cover_art.dart';
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
  // Trash first, then tags and art, then moves. Order matters: writing
  // to a file and then moving it means the journal's entry names a path
  // that no longer exists, and undo would fail to find it.
  //
  // In practice art never shares a run with moves — [validatePlan]
  // refuses that combination — but the order is correct either way
  // rather than correct by assumption.
  final actions = [
    ...plan.trashes,
    ...plan.retags,
    ...plan.art,
    ...plan.moves,
  ];

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

  // Checked first, because for this one action [path] is a file that is
  // meant not to exist yet — the guard below would read that as a
  // failure.
  if (action.kind == ActionKind.writeCover) {
    return _writeCoverFile(action, now);
  }

  if (!source.existsSync()) {
    // Distinguishing why matters more than it looks. The commonest cause
    // by far is that an earlier run already moved the file — in which
    // case the plan is simply stale, and reporting it as a missing file
    // sends you looking for a problem with the collection instead.
    final parentExists = source.parent.existsSync();
    return JournalEntry(
      kind: action.kind,
      path: action.path,
      targetPath: action.targetPath,
      at: now,
      error: parentExists
          ? 'not here any more — most likely already moved by an '
              'earlier run, so this plan is out of date'
          : 'the folder it was in is gone, so this plan is out of date',
    );
  }

  switch (action.kind) {
    case ActionKind.writeCover:
      // Handled above, before the existence check.
      throw StateError('unreachable');

    case ActionKind.embedArt:
      final art = await _readArt(action.artFrom);
      if (art == null) {
        return JournalEntry(
          kind: action.kind,
          path: action.path,
          at: now,
          error: 'could not read a cover from ${action.artFrom}',
        );
      }

      // Refusing to overwrite. Art is only planned for files that had
      // none, so finding one here means the file changed since the art
      // scan — and replacing somebody's cover is not what was asked for.
      try {
        final before = readMetadata(source, getImage: true);
        if (before.pictures.isNotEmpty) {
          return JournalEntry(
            kind: action.kind,
            path: action.path,
            at: now,
            error: 'it already has a cover now — nothing was changed',
          );
        }
      } catch (_) {
        // Unreadable tags are not a reason to refuse to write a cover;
        // the same rule the retag path follows.
      }

      updateMetadata(source, (m) {
        m.setPictures(
            [Picture(art.bytes, art.mimeType, PictureType.coverFront)]);
      });

      // Read back, because the write can do nothing and say nothing.
      //
      // An MP3 with no ID3v2 tag at all — a plain stream of frames, which
      // a good number of older rips are — accepts `setPictures` without
      // complaint, writes zero bytes, and leaves the file byte-identical.
      // Verified against a tagless file: no exception, no change in
      // length, no picture afterwards. Without this check the app would
      // report four thousand covers written while several hundred files
      // got nothing, and the only way to find out would be noticing the
      // covers were still missing.
      var landed = false;
      try {
        landed = readMetadata(source, getImage: true).pictures.isNotEmpty;
      } catch (_) {
        // Unreadable after writing is its own kind of wrong; treated as
        // not landed, which is the safe reading.
      }
      if (!landed) {
        return JournalEntry(
          kind: action.kind,
          path: action.path,
          at: now,
          error: 'the cover would not stick — this file has no ID3v2 tag '
              'for one to go in',
        );
      }

      return JournalEntry(
        kind: ActionKind.embedArt,
        path: action.path,
        at: now,
      );

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

/// A cover, ready to write.
class _Art {
  const _Art(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;
}

/// Reads a cover out of whatever it was told to read it from.
///
/// Two shapes, because the offline pass finds art in two places: inside
/// another track on the album, and in an image file beside it. A
/// downloaded cover arrives as the second of those — written to a cache
/// file first so an art action is always just a pair of paths.
///
/// The bytes are sniffed rather than trusted. An extension is a claim,
/// and embedding a PNG labelled `image/jpeg` produces a cover that some
/// players show and others silently drop.
Future<_Art?> _readArt(String? from) async {
  if (from == null || from.isEmpty) return null;
  final file = File(from);
  if (!file.existsSync()) return null;

  if (from.toLowerCase().endsWith('.mp3')) {
    try {
      final meta = readMetadata(file, getImage: true);
      if (meta.pictures.isEmpty) return null;
      // The front cover if the file says which is which, otherwise the
      // first picture — a file with one untyped picture is the common
      // case, and that picture is the cover.
      final picture = meta.pictures.firstWhere(
        (p) => p.pictureType == PictureType.coverFront,
        orElse: () => meta.pictures.first,
      );
      final sniffed = sniffImageType(picture.bytes);
      if (sniffed == null || !kEmbeddableTypes.contains(sniffed)) return null;
      return _Art(picture.bytes, sniffed);
    } catch (_) {
      return null;
    }
  }

  final bytes = await file.readAsBytes();
  final sniffed = sniffImageType(bytes);
  if (sniffed == null || !kEmbeddableTypes.contains(sniffed)) return null;
  return _Art(bytes, sniffed);
}

/// Writes a `cover.jpg` beside an album.
///
/// Never over an existing file. A cover already sitting there was put
/// there by somebody — possibly a better one than this — and the whole
/// arrangement of this app is that nothing is replaced without being
/// shown first.
Future<JournalEntry> _writeCoverFile(PlannedAction action, DateTime now) async {
  final destination = File(action.path);

  if (destination.existsSync()) {
    return JournalEntry(
      kind: action.kind,
      path: action.path,
      at: now,
      error: 'a cover is already there — it was left alone',
    );
  }

  final art = await _readArt(action.artFrom);
  if (art == null) {
    return JournalEntry(
      kind: action.kind,
      path: action.path,
      at: now,
      error: 'could not read a cover from ${action.artFrom}',
    );
  }

  await destination.parent.create(recursive: true);
  await destination.writeAsBytes(art.bytes, flush: true);

  return JournalEntry(kind: action.kind, path: action.path, at: now);
}

/// Moves a file, falling back to copy-and-delete across filesystems.
///
/// `rename` fails with EXDEV between devices, and on Android it can fail
/// on a removable card for reasons of its own, so the fallback is not
/// exotic — on the device that found this bug it was the normal path.
///
/// **A failed move must leave nothing behind.** The version without that
/// guarantee copied the file, failed to remove the original, reported the
/// action as failed, and left a duplicate: the original still in place and
/// a copy at the destination. On a real collection that produced 244
/// duplicate groups and a folder the owner could see was untouched while
/// the app insisted the files had been filed.
///
/// So the copy is verified by length, and if the original cannot then be
/// removed the copy is undone before the failure is reported.
Future<void> _moveFile(File source, String target) async {
  try {
    await source.rename(target);
    return;
  } on FileSystemException {
    // Cross-device, or a filesystem that will not rename across
    // directories. Fall through to copy and delete.
  }

  final copied = await source.copy(target);

  if (await copied.length() != await source.length()) {
    await _deleteQuietly(copied);
    throw FileSystemException('the copy came out a different size', target);
  }

  try {
    await source.delete();
  } on FileSystemException catch (e) {
    // The dangerous case. Both files exist right now, and leaving it
    // that way is how a collection silently doubles.
    await _deleteQuietly(copied);
    throw FileSystemException(
      'copied it, but could not remove the original '
      '(${e.osError?.message ?? e.message}) — the copy was undone so '
      'nothing is duplicated',
      source.path,
    );
  }
}

/// Removes a file, swallowing whatever goes wrong.
///
/// Used only when already handling a failure: the error that matters is
/// the one being reported, and a failure to clean up should not replace
/// it with a less useful one.
Future<void> _deleteQuietly(File file) async {
  try {
    if (file.existsSync()) await file.delete();
  } catch (_) {
    // Nothing useful to do, and the caller is already throwing.
  }
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

        case ActionKind.embedArt:
          final f = File(e.path);
          if (!f.existsSync()) {
            throw FileSystemException('file is gone', e.path);
          }
          // Cleared outright rather than restored. Art is only ever
          // embedded into files that had none — apply re-checks that
          // immediately before writing — so "what it was before" is
          // nothing, and that is what it goes back to.
          updateMetadata(f, (m) => m.setPictures(const []));

        case ActionKind.writeCover:
          final cover = File(e.path);
          // Only a cover this run created is journalled, so removing it
          // cannot take somebody else's. A cover already gone is not a
          // failure — there is nothing left to undo.
          if (cover.existsSync()) await cover.delete();
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
