/// Grouping the plan into artists and records for the review.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/shelf.dart';
import 'package:mp3sorter/track.dart';

PlannedAction move(String path, {String? artist, String? album}) =>
    PlannedAction(
      kind: ActionKind.move,
      path: path,
      targetPath: '/out/$path',
      shelfArtist: artist,
      shelfAlbum: album,
    );

void main() {
  test('actions are grouped by artist, then album', () {
    final shelves = shelve([
      move('a', artist: 'Muse', album: 'Absolution'),
      move('b', artist: 'Muse', album: 'Origin of Symmetry'),
      move('c', artist: 'Muse', album: 'Absolution'),
      move('d', artist: 'Blur', album: 'Parklife'),
    ]);
    expect([for (final s in shelves) s.name], ['Blur', 'Muse']);
    final muse = shelves[1];
    expect([for (final a in muse.albums) a.title],
        ['Absolution', 'Origin of Symmetry']);
    expect([for (final a in muse.albums.first.actions) a.path], ['a', 'c']);
    expect(muse.actions, hasLength(3));
  });

  test('spellings differing only in case are one sleeve', () {
    final shelves = shelve([
      move('a', artist: 'Muse', album: 'Absolution'),
      move('b', artist: 'muse', album: 'absolution'),
    ]);
    expect(shelves, hasLength(1));
    expect(shelves.single.name, 'Muse');
    expect(shelves.single.albums.single.actions, hasLength(2));
  });

  test('loose tracks go last, and the nameless artist after everyone', () {
    final shelves = shelve([
      move('a', artist: 'Muse'),
      move('b', artist: 'Muse', album: 'Absolution'),
      move('c'),
      move('d', artist: 'Zappa', album: '  '),
    ]);
    expect([for (final s in shelves) s.name], ['Muse', 'Zappa', null]);
    expect([for (final a in shelves.first.albums) a.title],
        ['Absolution', null]);
    expect(shelves[1].albums.single.isLoose, isTrue);
  });

  test('"The" is filed under the next word', () {
    final shelves = shelve([
      move('a', artist: 'The Beatles'),
      move('b', artist: 'Blur'),
      move('c', artist: 'ABBA'),
    ]);
    expect([for (final s in shelves) s.name], ['ABBA', 'The Beatles', 'Blur']);
  });

  test('inclusion reads all, some and none', () {
    final actions = [move('a'), move('b')];
    expect(inclusionOf(actions, (_) => false), Inclusion.all);
    expect(inclusionOf(actions, (a) => a.path == 'a'), Inclusion.some);
    expect(inclusionOf(actions, (_) => true), Inclusion.none);
  });

  test('the planner says who and which record each change is for', () {
    final plan = buildPlan([
      const Track(
          path: '/m/x/Bomb.mp3',
          sizeBytes: 1,
          artist: 'band of skulls',
          title: 'Bomb',
          album: 'Baby Darling Doll Face Honey',
          trackNumber: 8),
      const Track(
          path: '/m/x/Fires.mp3',
          sizeBytes: 1,
          artist: 'Band of Skulls',
          title: 'Fires',
          album: 'Baby Darling Doll Face Honey'),
    ], const PlanOptions(root: '/m/_sorted', sourceRoot: '/m'));

    for (final a in [...plan.moves, ...plan.retags]) {
      expect(a.shelfArtist?.toLowerCase(), 'band of skulls');
      expect(a.shelfAlbum, 'Baby Darling Doll Face Honey');
    }
    expect(plan.moves, isNotEmpty);
  });
}
