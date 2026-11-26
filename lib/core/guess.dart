/// Guessing tags from a file's name and the folders it sits in.
///
/// The offline half of the suggestions: always available, no network, and
/// often right for collections ripped or downloaded with sensible names.
/// Pure string work, tested against real names from a real collection.
library;

import 'tags.dart';

/// Folder names that say nothing about the music in them.
const Set<String> _genericFolders = {
  'music',
  'musik',
  'audio',
  'mp3',
  'mp3s',
  'flac',
  'songs',
  'downloads',
  'download',
  'sorted',
  '_sorted',
  'unsorted',
  '0_unsorted',
  'other',
  'misc',
  'new folder',
  'unknown',
  'unknown album',
  'unknown artist',
  'various',
  'various artists',
  'various_artists',
  'albums',
  'singles',
  'eps',
};

final RegExp _discTrackPrefix = RegExp(r'^(\d{1,2})[-.](\d{1,3})[\s._-]+');
final RegExp _trackPrefix = RegExp(r'^(\d{1,3})(?:\s*[-._)]\s*|\s+)');
final RegExp _noise = RegExp(
  r'[\[(][^\])]*(official|video|audio|lyrics?|lyric video|visuali[sz]er|hd|hq|4k|mv|m/v|cbr|kbps)[^\])]*[\])]'
  r'|\b(official (music )?video|official audio|lyric video|cbr \d+k|\d{2,3} ?kbps)\b',
  caseSensitive: false,
);
final RegExp _yearBracket = RegExp(r'^[\[(]((?:19|20)\d\d)[\])]\s*');
final RegExp _yearLead = RegExp(r'^((?:19|20)\d\d)[\s_-]+');
final RegExp _trailingId = RegExp(r'[\s_-]+\d{5,}$');
final RegExp _spaces = RegExp(r'\s+');

/// Turns `snake_case` and `kebab-case` names into words.
///
/// Underscores always become spaces: nobody's artist is really called
/// `blue_oyster_cult`. Hyphens become spaces only when the name has no spaces
/// at all and is clearly hyphen-joined words (`norman-fucking-rockwell`);
/// otherwise a hyphen may be the artist–title separator and is left for
/// [splitArtistTitle].
String humanise(String raw) {
  var s = raw.replaceAll('_', ' ');
  s = s.replaceAll(_spaces, ' ').trim();
  return s;
}

/// Capitalises words in an all-lowercase name. Mixed case is left exactly as
/// it is — `AC/DC`, `deadmau5` with a capital-free brand, or `iPhone` are
/// the owner's spelling, not ours to fix.
String titleCaseIfLower(String s) {
  if (s != s.toLowerCase()) return s;
  return s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

String _stripNoise(String s) =>
    s.replaceAll(_noise, ' ').replaceAll(_spaces, ' ').trim();

/// Splits `Artist - Title`. Returns null when there is no separator.
///
/// ` - ` (spaced) is trusted first. A bare `-` is only used when the name had
/// underscores for spaces and no spaced dash — the `shinedown-if_you_only_knew`
/// shape — because in a normal name a bare hyphen is far more often part of a
/// word (`Jay-Z`, `Re-Education`).
(String, String)? splitArtistTitle(String name, {required bool wasSnake}) {
  final spaced = name.indexOf(' - ');
  if (spaced > 0) {
    final a = name.substring(0, spaced).trim();
    final t = name.substring(spaced + 3).trim();
    if (a.isNotEmpty && t.isNotEmpty) return (a, t);
  }
  if (wasSnake) {
    final bare = name.indexOf('-');
    if (bare > 0 && bare < name.length - 1) {
      final a = name.substring(0, bare).trim();
      final t = name.substring(bare + 1).trim();
      if (a.isNotEmpty && t.isNotEmpty) return (a, t);
    }
  }
  return null;
}

/// What a filename says.
class FilenameGuess {
  const FilenameGuess({this.artist, this.title, this.trackNumber, this.disc});
  final String? artist;
  final String? title;
  final int? trackNumber;
  final int? disc;
}

/// Reads artist, title and track number out of a file's base name.
FilenameGuess guessFromFilename(String fileName) {
  var base = fileName;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);

  final wasSnake = base.contains('_') && !base.contains(' ');

  int? track;
  int? disc;
  final dt = _discTrackPrefix.firstMatch(base);
  if (dt != null) {
    disc = int.tryParse(dt.group(1)!);
    track = int.tryParse(dt.group(2)!);
    base = base.substring(dt.end);
  } else {
    final t = _trackPrefix.firstMatch(base);
    // A name that is *only* a number ("24.mp3") is a track number with no
    // title, not a title of "24" — but it is also not worth guessing from.
    if (t != null && t.end < base.length) {
      track = int.tryParse(t.group(1)!);
      base = base.substring(t.end);
    }
  }

  base = humanise(base);
  base = _stripNoise(base);

  String? artist;
  String title = base;
  final split = splitArtistTitle(base, wasSnake: wasSnake);
  if (split != null) {
    artist = split.$1;
    title = split.$2;
  }

  // "60-linkin_park-grr_(1999_demo)": after the track number is taken, a
  // snake name can still carry the artist as its first dash field. Handled by
  // splitArtistTitle above; what is left here is casing.
  if (wasSnake) {
    if (artist != null) artist = titleCaseIfLower(artist);
    title = titleCaseIfLower(title);
  }

  return FilenameGuess(
    artist: (artist == null || artist.isEmpty) ? null : artist,
    title: title.isEmpty ? null : title,
    trackNumber: track,
    disc: disc,
  );
}

/// What the folders say.
class FolderGuess {
  const FolderGuess({this.artist, this.album, this.year});
  final String? artist;
  final String? album;
  final int? year;
}

bool _isGeneric(String name) =>
    _genericFolders.contains(name.toLowerCase().trim());

/// Cleans one folder name into an album or artist name, pulling out a year
/// when it leads (`[2005] Wolfmother`, `2019_norman-fucking-rockwell_218434`).
(String?, int?) cleanFolderName(String raw) {
  var s = raw.trim();
  if (_isGeneric(s)) return (null, null);
  int? year;
  final yb = _yearBracket.firstMatch(s);
  if (yb != null) {
    year = int.parse(yb.group(1)!);
    s = s.substring(yb.end);
  } else {
    final yl = _yearLead.firstMatch(s);
    if (yl != null) {
      year = int.parse(yl.group(1)!);
      s = s.substring(yl.end);
    }
  }
  s = s.replaceAll(_trailingId, '');
  final wasSnakeOrKebab = !s.contains(' ') && (s.contains('_') || s.contains('-'));
  s = s.replaceAll('_', ' ');
  if (wasSnakeOrKebab) s = s.replaceAll('-', ' ');
  s = s.replaceAll(_spaces, ' ').trim();
  if (wasSnakeOrKebab) s = titleCaseIfLower(s);
  return (s.isEmpty || _isGeneric(s) ? null : s, year);
}

/// Reads album and artist from the two folders above a file, stopping at
/// [root] — the folder the user picked, which is a container, not an album.
FolderGuess guessFromFolders(String filePath, String root) {
  final sep = filePath.contains('\\') ? '\\' : '/';
  var rel = filePath;
  final normRoot = root.endsWith(sep) ? root : '$root$sep';
  if (filePath.startsWith(normRoot)) rel = filePath.substring(normRoot.length);
  final parts = rel.split(sep)..removeLast(); // drop the file name
  if (parts.isEmpty) return const FolderGuess();

  final parent = parts.last;
  if (_isGeneric(parent)) return const FolderGuess();
  final (album, year) = cleanFolderName(parent);

  String? artist;
  if (parts.length >= 2) {
    final (a, _) = cleanFolderName(parts[parts.length - 2]);
    artist = a;
  }
  return FolderGuess(artist: artist, album: album, year: year);
}

/// The offline candidates for one file: what its name says, and what its
/// folders add to that.
List<Candidate> offlineCandidates({
  required String filePath,
  required String root,
}) {
  final name = filePath.split(RegExp(r'[\\/]')).last;
  final f = guessFromFilename(name);
  final d = guessFromFolders(filePath, root);

  final out = <Candidate>[];
  final fromName = TagSet(
    artist: f.artist,
    title: f.title,
    trackNumber: f.trackNumber,
  );
  if (!fromName.normalised().isEmpty) {
    out.add(Candidate(
      label: 'From filename',
      source: CandidateSource.filename,
      tags: fromName,
      score: 20,
    ));
  }
  if (d.album != null || d.artist != null) {
    out.add(Candidate(
      label: 'From folders',
      source: CandidateSource.folder,
      tags: TagSet(
        artist: f.artist ?? d.artist,
        title: f.title,
        album: d.album,
        albumArtist: d.artist,
        year: d.year,
        trackNumber: f.trackNumber,
      ),
      score: 30,
    ));
  }
  return out;
}
