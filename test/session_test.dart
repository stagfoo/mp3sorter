/// Saving a scan and loading it back.
///
/// The round trip has to be exact, because the whole point is to skip a
/// three-minute rescan — a lossy save would quietly plan against worse
/// information than the scan had.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/session_file.dart';
import 'package:mp3sorter/track.dart';

Track t(String path, {String? artist, String? title, int? kbps = 192}) =>
    Track(
      path: path,
      sizeBytes: 4096,
      artist: artist,
      title: title,
      bitrateKbps: kbps,
      isVbr: true,
      sampleRate: 44100,
      duration: const Duration(seconds: 213),
      audioFingerprint: 'abc123',
      genres: const ['Rock'],
    );

void main() {
  group('round trip', () {
    test('every field survives', () {
      final original = Session(
        rootPath: '/music',
        tracks: [t('/music/a.mp3', artist: 'Muse', title: 'Hysteria')],
        scannedAt: DateTime.utc(2026, 10, 14, 11),
        scanSeconds: 163,
      );
      final back = decodeSession(encodeSession(original)).session;

      expect(back.rootPath, '/music');
      expect(back.scanSeconds, 163);
      final a = original.tracks.single, b = back.tracks.single;
      expect(b.path, a.path);
      expect(b.artist, a.artist);
      expect(b.title, a.title);
      expect(b.bitrateKbps, a.bitrateKbps);
      expect(b.isVbr, a.isVbr);
      expect(b.sampleRate, a.sampleRate);
      expect(b.duration, a.duration);
      expect(b.audioFingerprint, a.audioFingerprint);
      expect(b.genres, a.genres);
      expect(b.sizeBytes, a.sizeBytes);
    });

    test('a track with nothing but a path survives', () {
      final back = decodeSession(encodeSession(Session(
        rootPath: '/m',
        tracks: [const Track(path: '/m/x.mp3', sizeBytes: 0)],
        scannedAt: DateTime.now(),
      ))).session;
      expect(back.tracks.single.path, '/m/x.mp3');
      expect(back.tracks.single.artist, isNull);
    });

    test('an empty scan round-trips', () {
      final back = decodeSession(encodeSession(
              Session(rootPath: '/m', tracks: [], scannedAt: DateTime.now())))
          .session;
      expect(back.tracks, isEmpty);
    });
  });

  group('refusing what is not ours', () {
    test('not JSON', () {
      expect(() => decodeSession('just some text'),
          throwsA(isA<SessionFormatException>()));
    });

    test('JSON, but somebody else\'s', () {
      expect(() => decodeSession('{"hello":"world"}'),
          throwsA(isA<SessionFormatException>()));
    });
  });

  group('keeping what is usable', () {
    test('a malformed row costs that row, not the file', () {
      final json = '{"format":"$kSessionMagic","version":1,"root":"/m",'
          '"tracks":[{"path":"/m/a.mp3","size":1},{"nope":true},'
          '{"path":"/m/b.mp3","size":2}]}';
      final r = decodeSession(json);
      expect(r.session.tracks, hasLength(2));
      expect(r.skipped, 1);
    });

    test('a file from a newer build is read, and flagged', () {
      final json = '{"format":"$kSessionMagic","version":99,"root":"/m",'
          '"tracks":[{"path":"/m/a.mp3","size":1}]}';
      final r = decodeSession(json);
      expect(r.fromNewerBuild, isTrue);
      expect(r.session.tracks, hasLength(1));
    });

    test('an unknown field is ignored rather than fatal', () {
      final json = '{"format":"$kSessionMagic","version":1,"root":"/m",'
          '"tracks":[{"path":"/m/a.mp3","size":1,"somethingNew":42}]}';
      expect(decodeSession(json).session.tracks, hasLength(1));
    });
  });
}
