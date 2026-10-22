/// The plan arranged the way a collection is held: artists, then records.
///
/// A flat list of five thousand changes asks the reader to recognise
/// `Bomb.mp3` on sight. Nobody can; what they can recognise is a sleeve
/// and a name. So the review is built on this grouping, and a whole
/// artist or a whole album can be taken out of the plan in one go —
/// which is the decision people actually make ("leave my Ghibli
/// soundtracks alone"), rather than five hundred individual ones.
///
/// Pure: actions in, groups out. No files, no widgets.
library;

import 'plan.dart';

/// One record's worth of changes.
class AlbumShelf {
  AlbumShelf({required this.artist, required this.title, required this.actions});

  final String? artist;

  /// Null for tracks with no album — singles and loose files. Shown as
  /// such rather than as an invented `Unknown Album`, for the reason the
  /// planner gives in `targetFor`.
  final String? title;

  final List<PlannedAction> actions;

  bool get isLoose => title == null;

  /// Stable across rebuilds, so a cover loaded once is found again.
  String get key => '${artist ?? ''}\u0000${title ?? ''}';
}

/// One artist's worth of records.
class ArtistShelf {
  ArtistShelf({required this.name, required this.albums});

  /// Null when the planner could not tell who this is.
  final String? name;
  final List<AlbumShelf> albums;

  late final List<PlannedAction> actions = [
    for (final a in albums) ...a.actions,
  ];

  String get key => name ?? '';
}

/// Groups [actions] by artist and then album.
///
/// Artists are matched case-insensitively, because `Muse` and `muse`
/// on two retags are one sleeve to a person even when the planner left
/// them apart. The first spelling seen names the group.
///
/// Ordered alphabetically, loose tracks last within an artist and the
/// artist nobody could name last of all — it is the group most worth a
/// look, but it is not a letter of the alphabet.
List<ArtistShelf> shelve(Iterable<PlannedAction> actions) {
  final artistNames = <String, String?>{};
  final byArtist = <String, Map<String, (String?, List<PlannedAction>)>>{};

  for (final a in actions) {
    final artist = _clean(a.shelfArtist);
    final album = _clean(a.shelfAlbum);
    final artistKey = artist?.toLowerCase() ?? '';
    artistNames.putIfAbsent(artistKey, () => artist);
    final albums = byArtist.putIfAbsent(artistKey, () => {});
    final albumKey = album?.toLowerCase() ?? '';
    albums.putIfAbsent(albumKey, () => (album, <PlannedAction>[])).$2.add(a);
  }

  final shelves = <ArtistShelf>[];
  byArtist.forEach((artistKey, albums) {
    final name = artistNames[artistKey];
    final records = [
      for (final (title, list) in albums.values)
        AlbumShelf(artist: name, title: title, actions: list),
    ]..sort(_albumOrder);
    shelves.add(ArtistShelf(name: name, albums: records));
  });
  shelves.sort(_artistOrder);
  return shelves;
}

String? _clean(String? s) {
  final t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}

int _albumOrder(AlbumShelf a, AlbumShelf b) {
  if (a.isLoose != b.isLoose) return a.isLoose ? 1 : -1;
  return (a.title ?? '').toLowerCase().compareTo((b.title ?? '').toLowerCase());
}

int _artistOrder(ArtistShelf a, ArtistShelf b) {
  if ((a.name == null) != (b.name == null)) return a.name == null ? 1 : -1;
  return _sortName(a.name ?? '').compareTo(_sortName(b.name ?? ''));
}

/// `The Beatles` files under B, the way a record shop would have it.
String _sortName(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('the ') ? lower.substring(4) : lower;
}

/// How much of a group is still in the plan.
enum Inclusion { all, some, none }

Inclusion inclusionOf(
    Iterable<PlannedAction> actions, bool Function(PlannedAction) isRejected) {
  var kept = 0;
  var total = 0;
  for (final a in actions) {
    total++;
    if (!isRejected(a)) kept++;
  }
  if (kept == 0) return Inclusion.none;
  return kept == total ? Inclusion.all : Inclusion.some;
}
