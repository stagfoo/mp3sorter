/// Applying a plan and taking it back, against real files in a temp dir.
///
/// These touch the filesystem on purpose — the things worth testing here
/// are exactly the ones a pure function cannot have: a target that
/// already exists, a source that vanished between scan and apply, a
/// journal truncated by a crash. Every case runs in a directory created
/// and destroyed by the test.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/apply.dart';
import 'package:mp3sorter/plan.dart';

late Directory tmp;

String p(String relative) => '${tmp.path}/$relative';

File write(String relative, [String content = 'audio']) {
  final f = File(p(relative));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
  return f;
}

Journal journalIn() => Journal(File(p('.journal.jsonl')));

Plan planOf({
  List<PlannedAction> moves = const [],
  List<PlannedAction> trashes = const [],
}) =>
    Plan(
      moves: moves,
      retags: const [],
      trashes: trashes,
      artistMerges: const {},
      unsortable: const [],
    );

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('mp3sorter_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('moving files', () {
    test('a file is moved and the journal records it', () async {
      write('in/song.mp3');
      final j = journalIn();
      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('in/song.mp3'),
              targetPath: p('out/Muse/Hysteria.mp3')),
        ]),
        j,
      );

      expect(r.allSucceeded, isTrue);
      expect(File(p('out/Muse/Hysteria.mp3')).existsSync(), isTrue);
      expect(File(p('in/song.mp3')).existsSync(), isFalse);
      expect((await j.read()).single.kind, ActionKind.move);
    });

    test('missing parent directories are created', () async {
      write('a.mp3');
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('a.mp3'),
              targetPath: p('x/y/z/a.mp3')),
        ]),
        journalIn(),
      );
      expect(File(p('x/y/z/a.mp3')).existsSync(), isTrue);
    });

    test('an existing target is refused, never overwritten', () async {
      // The one mistake with no undo.
      write('a.mp3', 'new');
      write('out/a.mp3', 'precious');
      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('a.mp3'),
              targetPath: p('out/a.mp3')),
        ]),
        journalIn(),
      );

      expect(r.failed, 1);
      expect(File(p('out/a.mp3')).readAsStringSync(), 'precious');
      expect(File(p('a.mp3')).existsSync(), isTrue,
          reason: 'the source must survive a refused move');
    });

    test('a source that vanished is reported, not thrown', () async {
      // The collection can change between the scan and the apply.
      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('ghost.mp3'),
              targetPath: p('out/ghost.mp3')),
        ]),
        journalIn(),
      );
      expect(r.failed, 1);
      // The message has to say the plan is stale, not just that a file is
      // missing: on a device this produced 249 identical "file no longer
      // exists" lines after a run that had already moved everything, and
      // nothing on screen explained that.
      expect(r.errors.single, contains('out of date'));
    });

    test('one failure does not abandon the rest of the run', () async {
      write('good1.mp3');
      write('good2.mp3');
      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('good1.mp3'),
              targetPath: p('out/1.mp3')),
          PlannedAction(
              kind: ActionKind.move,
              path: p('missing.mp3'),
              targetPath: p('out/2.mp3')),
          PlannedAction(
              kind: ActionKind.move,
              path: p('good2.mp3'),
              targetPath: p('out/3.mp3')),
        ]),
        journalIn(),
      );
      expect(r.succeeded, 2);
      expect(r.failed, 1);
      expect(File(p('out/3.mp3')).existsSync(), isTrue,
          reason: 'the action after the failure must still run');
    });

    test('progress is reported for every action', () async {
      write('a.mp3');
      write('b.mp3');
      final seen = <int>[];
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move, path: p('a.mp3'), targetPath: p('o/a.mp3')),
          PlannedAction(
              kind: ActionKind.move, path: p('b.mp3'), targetPath: p('o/b.mp3')),
        ]),
        journalIn(),
        onProgress: (done, total) => seen.add(done),
      );
      expect(seen, [1, 2]);
    });
  });

  group('trashing', () {
    test('a removed duplicate is moved, never unlinked', () async {
      write('dupe.mp3', 'contents');
      await applyPlan(
        planOf(trashes: [
          PlannedAction(
              kind: ActionKind.trash,
              path: p('dupe.mp3'),
              targetPath: p('.trash/dupe.mp3')),
        ]),
        journalIn(),
      );
      expect(File(p('dupe.mp3')).existsSync(), isFalse);
      expect(File(p('.trash/dupe.mp3')).readAsStringSync(), 'contents');
    });
  });

  group('undo', () {
    test('a move is reversed', () async {
      write('in/song.mp3', 'audio');
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('in/song.mp3'),
              targetPath: p('out/song.mp3')),
        ]),
        j,
      );

      final r = await undo(j);
      expect(r.allSucceeded, isTrue);
      expect(File(p('in/song.mp3')).readAsStringSync(), 'audio');
      expect(File(p('out/song.mp3')).existsSync(), isFalse);
    });

    test('a trashed file comes back', () async {
      write('dupe.mp3', 'contents');
      final j = journalIn();
      await applyPlan(
        planOf(trashes: [
          PlannedAction(
              kind: ActionKind.trash,
              path: p('dupe.mp3'),
              targetPath: p('.trash/dupe.mp3')),
        ]),
        j,
      );
      await undo(j);
      expect(File(p('dupe.mp3')).readAsStringSync(), 'contents');
    });

    test('many moves are reversed in the right order', () async {
      write('a.mp3');
      write('b.mp3');
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move, path: p('a.mp3'), targetPath: p('o/a.mp3')),
          PlannedAction(
              kind: ActionKind.move, path: p('b.mp3'), targetPath: p('o/b.mp3')),
        ]),
        j,
      );
      await undo(j);
      expect(File(p('a.mp3')).existsSync(), isTrue);
      expect(File(p('b.mp3')).existsSync(), isTrue);
    });

    test('a successful undo clears the journal', () async {
      write('a.mp3');
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move, path: p('a.mp3'), targetPath: p('o/a.mp3')),
        ]),
        j,
      );
      await undo(j);
      expect(await j.read(), isEmpty);
    });

    test('a partial undo keeps the journal', () async {
      // Stranding files with no record of where they came from is worse
      // than a journal that is still there.
      write('a.mp3');
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move, path: p('a.mp3'), targetPath: p('o/a.mp3')),
        ]),
        j,
      );
      File(p('o/a.mp3')).deleteSync(); // something else removed it

      final r = await undo(j);
      expect(r.failed, 1);
      expect(await j.read(), isNotEmpty);
    });

    test('undo refuses when something is back at the original path',
        () async {
      write('a.mp3');
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move, path: p('a.mp3'), targetPath: p('o/a.mp3')),
        ]),
        j,
      );
      write('a.mp3', 'something else');

      final r = await undo(j);
      expect(r.failed, 1);
      expect(File(p('a.mp3')).readAsStringSync(), 'something else');
    });

    test('nothing to undo is not an error', () async {
      final r = await undo(journalIn());
      expect(r.allSucceeded, isTrue);
      expect(r.succeeded, 0);
    });
  });

  _failedMoveLeavesNothing();

  group('the journal format', () {
    test('a truncated final line costs one entry, not the file', () async {
      // What an interrupted run leaves behind. JSON Lines is chosen
      // precisely so the rest still reads.
      final f = File(p('.journal.jsonl'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        '${jsonEncode({
              'kind': 'move',
              'path': '/a.mp3',
              'targetPath': '/b.mp3',
              'at': DateTime.now().toIso8601String(),
            })}\n'
        '{"kind":"move","path":"/trunc',
      );
      expect((await Journal(f).read()), hasLength(1));
    });

    test('an action kind this build does not know is skipped', () async {
      final f = File(p('.journal.jsonl'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        '{"kind":"teleport","path":"/a.mp3","at":"2026-01-01T00:00:00Z"}\n'
        '{"kind":"move","path":"/b.mp3","targetPath":"/c.mp3",'
        '"at":"2026-01-01T00:00:00Z"}\n',
      );
      final entries = await Journal(f).read();
      expect(entries, hasLength(1));
      expect(entries.single.kind, ActionKind.move);
    });

    test('failures are recorded as well as successes', () async {
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('ghost.mp3'),
              targetPath: p('o/x.mp3')),
        ]),
        j,
      );
      final entries = await j.read();
      expect(entries, hasLength(1));
      expect(entries.single.succeeded, isFalse);
    });

    test('a failed entry is not replayed by undo', () async {
      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('ghost.mp3'),
              targetPath: p('o/x.mp3')),
        ]),
        j,
      );
      final r = await undo(j);
      expect(r.succeeded, 0);
      expect(r.failed, 0);
    });
  });
}

/// A failed move must leave nothing behind.
///
/// The invariant that broke on a device: the copy-and-delete fallback
/// copied the file, could not remove the original, reported failure —
/// and left both. The owner saw untouched folders while the app said the
/// files were filed, and the duplicate count climbed every run.
void _failedMoveLeavesNothing() {
  group('a move that fails part-way', () {
    test('leaves no copy behind when the original cannot be removed',
        () async {
      write('locked/song.mp3', 'audio');
      final sourceDir = Directory(p('locked'));
      // Removing write permission on the *directory* is what stops a
      // file inside it being unlinked, which is exactly the shape of the
      // Android failure.
      await Process.run('chmod', ['555', sourceDir.path]);
      addTearDown(() => Process.run('chmod', ['755', sourceDir.path]));

      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('locked/song.mp3'),
              targetPath: p('out/song.mp3')),
        ]),
        journalIn(),
      );

      expect(r.failed, 1, reason: 'it must report the failure');
      expect(File(p('locked/song.mp3')).existsSync(), isTrue,
          reason: 'the original is still the only copy');
      expect(File(p('out/song.mp3')).existsSync(), isFalse,
          reason: 'the half-made copy must be undone, not left as a '
              'duplicate');
    }, skip: Platform.isWindows);

    test('the failure says what actually happened', () async {
      write('locked2/song.mp3', 'audio');
      await Process.run('chmod', ['555', p('locked2')]);
      addTearDown(() => Process.run('chmod', ['755', p('locked2')]));

      final r = await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('locked2/song.mp3'),
              targetPath: p('out2/song.mp3')),
        ]),
        journalIn(),
      );
      expect(r.errors.single, contains('could not remove the original'));
      expect(r.errors.single, contains('nothing is duplicated'));
    }, skip: Platform.isWindows);

    test('a journalled failure is not replayed by undo', () async {
      write('locked3/song.mp3', 'audio');
      await Process.run('chmod', ['555', p('locked3')]);
      addTearDown(() => Process.run('chmod', ['755', p('locked3')]));

      final j = journalIn();
      await applyPlan(
        planOf(moves: [
          PlannedAction(
              kind: ActionKind.move,
              path: p('locked3/song.mp3'),
              targetPath: p('out3/song.mp3')),
        ]),
        j,
      );
      final r = await undo(j);
      expect(r.failed, 0);
      expect(File(p('locked3/song.mp3')).existsSync(), isTrue);
    }, skip: Platform.isWindows);
  });
}
