/// The bug report.
///
/// Worth testing because its whole job is to be accurate when something
/// has already gone wrong — a report that truncates or mis-groups is
/// worse than none, since it sends the reader somewhere else.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/diagnostics.dart';

void main() {
  group('grouping failures by cause', () {
    test('many files with one cause read as one cause', () {
      // The thing the screenshots could not show: 120 failures that all
      // said the same thing, which is what identified the bug.
      final errors = [
        for (var i = 0; i < 120; i++)
          '/music/_sorted/A/Song $i.mp3: something already exists at '
              '/music/_sorted/A/Song.mp3',
      ];
      final grouped = summariseErrors(errors);
      expect(grouped, hasLength(1));
      expect(grouped.values.single, 120);
    });

    test('different causes stay apart, commonest first', () {
      final grouped = summariseErrors([
        '/a.mp3: something already exists at /x.mp3',
        '/b.mp3: something already exists at /y.mp3',
        '/c.mp3: not here any more — out of date',
      ]);
      expect(grouped, hasLength(2));
      expect(grouped.values.first, 2);
    });

    test('a line with no path is kept whole', () {
      expect(summariseErrors(['something went wrong']),
          containsPair('something went wrong', 1));
    });

    test('nothing in, nothing out', () {
      expect(summariseErrors(const []), isEmpty);
    });
  });

  group('the report', () {
    String report({ApplyOutcome? lastRun}) => buildBugReport(
          appVersion: '1.2.3',
          platform: 'android 14',
          rootPath: '/storage/ABCD/Music',
          scan: null,
          plan: null,
          duplicates: const [],
          lastRun: lastRun,
          scanIsStale: true,
          now: DateTime.utc(2026, 10, 15, 9),
        );

    test('it carries what is needed to place the run', () {
      final r = report();
      expect(r, contains('1.2.3'));
      expect(r, contains('android 14'));
      expect(r, contains('/storage/ABCD/Music'));
      expect(r, contains('2026-10-15'));
      expect(r, contains('stale'));
    });

    test('every failure is listed, not the first few', () {
      // The rule the whole file exists for. Both device reports
      // truncated at eight and hid the pattern.
      final r = report(
        lastRun: ApplyOutcome(
          succeeded: 0,
          failed: 300,
          errors: [for (var i = 0; i < 300; i++) '/file$i.mp3: boom'],
        ),
      );
      expect(r, contains('/file0.mp3'));
      expect(r, contains('/file299.mp3'));
      expect(r, contains('failures (300)'));
    });

    test('it works before anything has been scanned', () {
      expect(buildBugReport(
        appVersion: '1.0.0',
        platform: 'linux',
        rootPath: null,
        scan: null,
        plan: null,
        duplicates: const [],
        lastRun: null,
        scanIsStale: false,
        now: DateTime.utc(2026),
      ), contains('none chosen'));
    });
  });
}
