/// The recent-folders list.
///
/// Small feature, but two of these rules are the difference between it
/// helping and getting in the way: one folder must not fill the list, and
/// an unmounted SD card must not empty it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/recent_folders.dart';

RecentFolder f(String path, {int daysAgo = 0, int files = 100}) =>
    RecentFolder(
      path: path,
      lastUsed: DateTime(2026, 10, 14).subtract(Duration(days: daysAgo)),
      fileCount: files,
    );

void main() {
  group('remembering a folder', () {
    test('the newest comes first', () {
      final list = remember([f('/a', daysAgo: 1)], f('/b'));
      expect(list.map((x) => x.path), ['/b', '/a']);
    });

    test('rescanning moves it up instead of adding a second entry', () {
      // Without this the list fills with one folder and remembers nothing.
      final list = remember(
        [f('/music', daysAgo: 5, files: 100), f('/other', daysAgo: 1)],
        f('/music', files: 3026),
      );
      expect(list.map((x) => x.path), ['/music', '/other']);
      expect(list.first.fileCount, 3026, reason: 'the count should update');
    });

    test('a trailing slash is the same folder', () {
      final list = remember([f('/music/')], f('/music'));
      expect(list, hasLength(1));
    });

    test('the list is capped', () {
      var list = <RecentFolder>[];
      for (var i = 0; i < 20; i++) {
        list = remember(list, f('/folder$i', daysAgo: 20 - i));
      }
      expect(list, hasLength(kMaxRecentFolders));
      expect(list.first.path, '/folder19', reason: 'newest survives');
    });

    test('forgetting removes exactly one', () {
      final list = forget([f('/a'), f('/b')], '/a');
      expect(list.map((x) => x.path), ['/b']);
    });

    test('forgetting something absent changes nothing', () {
      expect(forget([f('/a')], '/nope'), hasLength(1));
    });
  });

  group('labels', () {
    test('the folder name is the last segment', () {
      expect(f('/storage/1FA4-15A1/Music').name, 'Music');
      expect(f('/storage/emulated/0/Music/').name, 'Music');
    });

    test('two folders called Music are told apart by their parent', () {
      // The real case: an SD card and internal storage both have one.
      final sd = f('/storage/1FA4-15A1/Music');
      final internal = f('/storage/emulated/0/Music');
      expect(sd.name, internal.name);
      expect(sd.parentLabel, isNot(internal.parentLabel));
    });

    test('a root path does not crash the label', () {
      expect(f('/').name, isNotEmpty);
      expect(f('/').parentLabel, isNotEmpty);
    });
  });

  group('storage format', () {
    test('a round trip keeps every field', () {
      final original = [f('/music', files: 3026)];
      final back = decodeRecents(encodeRecents(original));
      expect(back.single.path, '/music');
      expect(back.single.fileCount, 3026);
      expect(back.single.lastUsed, original.single.lastUsed);
    });

    test('a malformed entry costs that entry, not the list', () {
      final back = decodeRecents(
          '[{"path":"/a","lastUsed":"2026-01-01T00:00:00.000"},'
          '{"nope":true},'
          '{"path":"/b","lastUsed":"2026-01-02T00:00:00.000"}]');
      expect(back.map((x) => x.path), ['/b', '/a']);
    });

    test('a corrupt file is an empty list, not a crash', () {
      // It is a convenience; the folder picker still works without it.
      expect(decodeRecents('not json at all'), isEmpty);
      expect(decodeRecents('{"not":"a list"}'), isEmpty);
      expect(decodeRecents(''), isEmpty);
    });

    test('an entry with no date still loads', () {
      final back = decodeRecents('[{"path":"/a"}]');
      expect(back.single.path, '/a');
    });

    test('it comes back newest first regardless of file order', () {
      final back = decodeRecents(
          '[{"path":"/old","lastUsed":"2020-01-01T00:00:00.000"},'
          '{"path":"/new","lastUsed":"2026-01-01T00:00:00.000"}]');
      expect(back.first.path, '/new');
    });
  });

  group('the unmounted-card rule', () {
    test('nothing here checks whether a folder exists', () {
      // Deliberate. The collection lives on a removable card, and
      // /storage/1FA4-15A1/Music does not exist while it is out —
      // pruning on existence would empty the list exactly when
      // remembering was useful. Existence is a display concern, checked
      // at render time, never a reason to forget.
      final list = remember(const [], f('/storage/1FA4-15A1/Music'));
      expect(list.single.path, '/storage/1FA4-15A1/Music');
      final reloaded = decodeRecents(encodeRecents(list));
      expect(reloaded.single.path, '/storage/1FA4-15A1/Music');
    });
  });
}
