/// The handful of tag fields this app edits, and the candidates offered
/// for them.
///
/// Pure data: no file access, no Flutter. Everything that decides *what*
/// gets written lives on top of these types and is tested on its own.
library;

/// The editable fields of one track.
///
/// Every field is optional. "Not set" and "set to empty" are the same thing
/// here: a blank field is never written as an empty frame, it is left alone.
class TagSet {
  const TagSet({
    this.artist,
    this.title,
    this.album,
    this.albumArtist,
    this.year,
    this.trackNumber,
    this.genre,
  });

  final String? artist;
  final String? title;
  final String? album;
  final String? albumArtist;
  final int? year;
  final int? trackNumber;
  final String? genre;

  static const TagSet empty = TagSet();

  bool get isEmpty =>
      _blank(artist) &&
      _blank(title) &&
      _blank(album) &&
      _blank(albumArtist) &&
      year == null &&
      trackNumber == null &&
      _blank(genre);

  /// Whitespace trimmed and blanks turned into nulls, so two sets that would
  /// write the same file compare equal.
  TagSet normalised() => TagSet(
        artist: _clean(artist),
        title: _clean(title),
        album: _clean(album),
        albumArtist: _clean(albumArtist),
        year: (year != null && year! > 0) ? year : null,
        trackNumber:
            (trackNumber != null && trackNumber! > 0) ? trackNumber : null,
        genre: _clean(genre),
      );

  /// Fields from [other] wherever it has one; this set's elsewhere.
  ///
  /// How a candidate chip is applied: it fills what it knows and leaves the
  /// rest of what is already in the editor, rather than blanking a track
  /// number just because MusicBrainz did not say one.
  TagSet overlaidWith(TagSet other) {
    final o = other.normalised();
    return TagSet(
      artist: o.artist ?? artist,
      title: o.title ?? title,
      album: o.album ?? album,
      albumArtist: o.albumArtist ?? albumArtist,
      year: o.year ?? year,
      trackNumber: o.trackNumber ?? trackNumber,
      genre: o.genre ?? genre,
    );
  }

  /// Only the album-level fields — what a batch applies to the rest of a
  /// folder. Title and track number are per-track by definition, and artist
  /// is left out because compilations and features vary it track by track;
  /// album artist is the one that is shared.
  TagSet albumFields() => TagSet(
        album: album,
        albumArtist: albumArtist,
        year: year,
        genre: genre,
      ).normalised();

  TagSet copyWith({
    String? artist,
    String? title,
    String? album,
    String? albumArtist,
    int? year,
    int? trackNumber,
    String? genre,
  }) =>
      TagSet(
        artist: artist ?? this.artist,
        title: title ?? this.title,
        album: album ?? this.album,
        albumArtist: albumArtist ?? this.albumArtist,
        year: year ?? this.year,
        trackNumber: trackNumber ?? this.trackNumber,
        genre: genre ?? this.genre,
      );

  Map<String, Object?> toJson() => {
        'artist': artist,
        'title': title,
        'album': album,
        'albumArtist': albumArtist,
        'year': year,
        'trackNumber': trackNumber,
        'genre': genre,
      };

  static TagSet fromJson(Map<String, Object?> j) => TagSet(
        artist: j['artist'] as String?,
        title: j['title'] as String?,
        album: j['album'] as String?,
        albumArtist: j['albumArtist'] as String?,
        year: (j['year'] as num?)?.toInt(),
        trackNumber: (j['trackNumber'] as num?)?.toInt(),
        genre: j['genre'] as String?,
      );

  @override
  bool operator ==(Object other) {
    if (other is! TagSet) return false;
    final a = normalised();
    final b = other.normalised();
    return a.artist == b.artist &&
        a.title == b.title &&
        a.album == b.album &&
        a.albumArtist == b.albumArtist &&
        a.year == b.year &&
        a.trackNumber == b.trackNumber &&
        a.genre == b.genre;
  }

  @override
  int get hashCode {
    final n = normalised();
    return Object.hash(n.artist, n.title, n.album, n.albumArtist, n.year,
        n.trackNumber, n.genre);
  }

  @override
  String toString() => 'TagSet(${toJson()})';
}

bool _blank(String? s) => s == null || s.trim().isEmpty;
String? _clean(String? s) => _blank(s) ? null : s!.trim();

/// Where a candidate came from. Shown on the chip, because "MusicBrainz
/// said so" and "the filename said so" deserve different amounts of trust.
enum CandidateSource { current, filename, folder, musicBrainz, lastFm }

/// One suggested set of tags — a chip on the card.
class Candidate {
  const Candidate({
    required this.label,
    required this.source,
    required this.tags,
    this.releaseId,
    this.releaseGroupId,
    this.lengthSeconds,
    this.score = 0,
  });

  /// What the chip says: "Official Release", "Live", "From filename"…
  final String label;
  final CandidateSource source;
  final TagSet tags;

  /// MusicBrainz ids, for fetching a cover once this candidate is chosen.
  final String? releaseId;
  final String? releaseGroupId;

  /// The recording's length according to the source, when it said.
  final int? lengthSeconds;

  /// Higher is better. Used only for ordering chips.
  final int score;

  /// A short second line for the chip's tooltip and the card.
  String get detail {
    final parts = <String>[
      if (tags.album != null) tags.album!,
      if (tags.year != null) '${tags.year}',
    ];
    return parts.join(' · ');
  }
}

/// Collapses candidates that would write the same tags, keeping the first
/// (the highest-ranked, given a sorted input) of each.
///
/// MusicBrainz in particular returns the same album once per pressing; six
/// chips that all say the same thing are noise.
List<Candidate> dedupeCandidates(Iterable<Candidate> input) {
  final seen = <TagSet>{};
  final out = <Candidate>[];
  for (final c in input) {
    final key = c.tags.normalised();
    if (key.isEmpty) continue;
    if (seen.add(key)) out.add(c);
  }
  return out;
}
