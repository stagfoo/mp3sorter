/// Filing shared credits, and artists chosen by hand, under another
/// artist's folder.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/levenshtein.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/shelf.dart';
import 'package:mp3sorter/track.dart';

Track t(String path, String artist, String title, {String? album}) => Track(
    path: path,
    sizeBytes: 1000,
    artist: artist,
    title: title,
    album: album,
    bitrateKbps: 192,
    duration: const Duration(minutes: 3));

Map<String, String> known(List<String> names) =>
    {for (final n in names) normaliseForMatching(n): n};

void main() {
  const opts = PlanOptions(root: '/M/_sorted', sourceRoot: '/M');

  group('the lead of a shared credit', () {
    test('is found when the collection already has them', () {
      final k = known(['Ado']);
      expect(leadArtist('Ado, Miku Hatsune', k), 'Ado');
      expect(leadArtist('Ado feat. Miku Hatsune', k), 'Ado');
      expect(leadArtist('Ado ft Miku', k), 'Ado');
      expect(leadArtist('Ado & Miku', k), 'Ado');
      expect(leadArtist('Ado x Miku', k), 'Ado');
      expect(leadArtist('Ado (feat. Miku)', k), 'Ado');
    });

    test('is nobody when the first name is not a known artist', () {
      // Splitting on every "&" would invent a "Mumford".
      expect(leadArtist('Mumford & Sons', known(['Mumford & Sons'])), isNull);
      expect(leadArtist('Jerry Douglas, Mumford & Sons',
          known(['Mumford & Sons'])), isNull);
    });

    test('is the first known name the credit starts with', () {
      expect(
          leadArtist('Lana Del Rey, A\$AP Rocky, Playboi Carti',
              known(['Lana Del Rey', 'Lana Del Rey, A\$AP Rocky'])),
          'Lana Del Rey');
      final k = known(['Mumford & Sons']);
      expect(leadArtist('Mumford & Sons & Dawes', k), 'Mumford & Sons');
      expect(leadArtist('Mumford & Sons, Dawes', k), 'Mumford & Sons');
    });

    test('needs a whole word, so "Band of Skulls" is not "B"', () {
      expect(leadArtist('Band of Skulls', known(['B'])), isNull);
    });
  });

  group('the plan', () {
    final tracks = [
      t('/M/a.mp3', 'Ado', 'Usseewa', album: 'Kyougen'),
      t('/M/b.mp3', 'Ado, Miku Hatsune', 'Ghost', album: 'Ghost'),
    ];

    test('files a shared credit in the lead artist\'s folder', () {
      final p = buildPlan(tracks, opts);
      final ghost = p.moves.firstWhere((m) => m.path == '/M/b.mp3');
      expect(ghost.targetPath, '/M/_sorted/Ado/Ghost.mp3');
      expect(ghost.shelfArtist, 'Ado');
      expect(ghost.reason, contains('credited to Ado, Miku Hatsune'));
      expect(p.filedUnder, {
        'Ado': ['Ado, Miku Hatsune']
      });
    });

    test('keeps the full credit in the tag', () {
      final p = buildPlan(tracks, opts);
      expect(p.retags.where((r) => r.artist != null), isEmpty);
    });

    test('shows the credit on the lead artist\'s shelf', () {
      final shelves = shelve(buildPlan(tracks, opts).moves);
      expect([for (final s in shelves) s.name], ['Ado']);
    });

    test('can be told to keep a credit in its own folder', () {
      final p = buildPlan(
          tracks,
          const PlanOptions(
              root: '/M/_sorted',
              sourceRoot: '/M',
              fileUnder: {'ado miku hatsune': 'Ado, Miku Hatsune'}));
      final ghost = p.moves.firstWhere((m) => m.path == '/M/b.mp3');
      expect(ghost.targetPath, '/M/_sorted/Ado, Miku Hatsune/Ghost.mp3');
      expect(p.filedUnder, isEmpty);
    });

    test('files any artist under any other by hand', () {
      final p = buildPlan([
        t('/M/a.mp3', 'Ado', 'Usseewa'),
        t('/M/c.mp3', 'Hatsune Miku', 'Ghost Rule'),
      ], const PlanOptions(
          root: '/M/_sorted',
          sourceRoot: '/M',
          fileUnder: {'hatsune miku': 'Ado'}));
      final rule = p.moves.firstWhere((m) => m.path == '/M/c.mp3');
      expect(rule.targetPath, '/M/_sorted/Ado/Ghost Rule.mp3');
    });

    test('follows a lead that was itself filed by hand', () {
      final p = buildPlan([
        t('/M/a.mp3', 'Ado', 'Usseewa'),
        t('/M/c.mp3', 'Hatsune Miku', 'Ghost Rule'),
        t('/M/d.mp3', 'Hatsune Miku, Kagamine Rin', 'Duet'),
      ], const PlanOptions(
          root: '/M/_sorted',
          sourceRoot: '/M',
          fileUnder: {'hatsune miku': 'Ado'}));
      final duet = p.moves.firstWhere((m) => m.path == '/M/d.mp3');
      expect(duet.targetPath, '/M/_sorted/Ado/Duet.mp3');
    });

    test('two choices pointing at each other do not hang', () {
      final p = buildPlan([
        t('/M/a.mp3', 'A', 'x'),
        t('/M/b.mp3', 'B', 'y'),
      ], const PlanOptions(
          root: '/M/_sorted',
          sourceRoot: '/M',
          fileUnder: {'a': 'B', 'b': 'A'}));
      expect(p.moves, hasLength(2));
    });

    test('can be switched off', () {
      final p = buildPlan(
          tracks,
          const PlanOptions(
              root: '/M/_sorted',
              sourceRoot: '/M',
              fileCollaborationsUnderLead: false));
      final ghost = p.moves.firstWhere((m) => m.path == '/M/b.mp3');
      expect(ghost.shelfArtist, 'Ado, Miku Hatsune');
    });
  });
}
