/// Fuzzy string matching for artist and track names.
///
/// Levenshtein distance is the easy half. The half that decides whether
/// this is useful on a real collection is **normalisation**: raw edit
/// distance says "The Beatles" and "Beatles" are 4 edits apart, which on
/// a 7-character string is a similarity of 0.64 — below any threshold you
/// would want to set, so the match is missed. Strip the leading article
/// first and they are identical.
///
/// So the pipeline is normalise, then compare, and most of the value is
/// in the normalisation rules below. Each one came from a real pattern in
/// a music collection rather than from a general string-matching text.
///
/// Plain Dart with no imports beyond `dart:math`, so all of it is testable
/// with `flutter test` and none of it depends on a device, a file, or a
/// tag library.
library;

import 'dart:math' as math;

/// Edit distance between two strings: the number of single-character
/// insertions, deletions or substitutions needed to turn one into the
/// other.
///
/// Two rows rather than a full matrix — only the previous row is ever
/// read, so the full n×m table is wasted memory. On the longest strings
/// here (a 200-character filename) that is the difference between 40,000
/// ints and 400.
int levenshtein(String a, String b) {
  if (identical(a, b) || a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  // The shorter string drives the row width, which keeps the allocation
  // small when comparing a short title against a long one.
  if (a.length > b.length) {
    final t = a;
    a = b;
    b = t;
  }

  final width = a.length + 1;
  var previous = List<int>.generate(width, (i) => i);
  var current = List<int>.filled(width, 0);

  for (var j = 1; j <= b.length; j++) {
    current[0] = j;
    final bj = b.codeUnitAt(j - 1);
    for (var i = 1; i < width; i++) {
      final cost = a.codeUnitAt(i - 1) == bj ? 0 : 1;
      final deletion = previous[i] + 1;
      final insertion = current[i - 1] + 1;
      final substitution = previous[i - 1] + cost;
      current[i] = math.min(math.min(deletion, insertion), substitution);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[a.length];
}

/// Edit distance, abandoned as soon as it is known to exceed [maxDistance].
///
/// Returns [maxDistance] + 1 to mean "further apart than you cared about".
///
/// This is what makes all-pairs comparison affordable. A collection of
/// 5,000 tracks is 12.5 million pairs, and the overwhelming majority are
/// nothing like each other — two strings whose lengths differ by more
/// than the threshold cannot possibly match, and most of the rest blow
/// the budget within a few rows. Running full Levenshtein on all of them
/// takes minutes; this takes seconds.
int levenshteinWithin(String a, String b, int maxDistance) {
  if (a == b) return 0;
  // A length difference is a lower bound on the distance: you need at
  // least that many insertions whatever else is going on.
  if ((a.length - b.length).abs() > maxDistance) return maxDistance + 1;
  if (a.isEmpty) return b.length <= maxDistance ? b.length : maxDistance + 1;
  if (b.isEmpty) return a.length <= maxDistance ? a.length : maxDistance + 1;

  if (a.length > b.length) {
    final t = a;
    a = b;
    b = t;
  }

  final width = a.length + 1;
  var previous = List<int>.generate(width, (i) => i);
  var current = List<int>.filled(width, 0);

  for (var j = 1; j <= b.length; j++) {
    current[0] = j;
    final bj = b.codeUnitAt(j - 1);
    var rowBest = current[0];
    for (var i = 1; i < width; i++) {
      final cost = a.codeUnitAt(i - 1) == bj ? 0 : 1;
      final v = math.min(
        math.min(previous[i] + 1, current[i - 1] + 1),
        previous[i - 1] + cost,
      );
      current[i] = v;
      if (v < rowBest) rowBest = v;
    }
    // Every later row is at least as large as the best value in this one,
    // so once the whole row is over budget the answer is too.
    if (rowBest > maxDistance) return maxDistance + 1;
    final swap = previous;
    previous = current;
    current = swap;
  }
  final d = previous[a.length];
  return d <= maxDistance ? d : maxDistance + 1;
}

/// How alike two strings are, from 0 (nothing in common) to 1 (identical).
///
/// Scaled by the longer string, so a one-character difference matters far
/// more in "Sia" than in "Florence and the Machine" — which is the right
/// behaviour: short names are distinct from each other on small margins,
/// and "Sia" vs "Mia" really are different artists.
double similarity(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final longest = math.max(a.length, b.length);
  if (longest == 0) return 1;
  return 1 - levenshtein(a, b) / longest;
}

/// Leading articles, which sort and compare badly.
///
/// A collection will contain "The National" and "National, The" and
/// "National" for the same band, because three different taggers made
/// three different choices.
final RegExp _leadingArticle = RegExp(r'^(the|a|an)\s+');
final RegExp _trailingArticle = RegExp(r',\s*(the|a|an)$');

/// Bracketed suffixes that describe the *release*, not the song.
///
/// "(Remastered 2011)", "[Explicit]", "(Deluxe Edition)" and friends are
/// why the same track appears to have six different titles. Deliberately
/// a fixed list of known-noise words rather than "strip all brackets":
/// plenty of real titles are parenthesised — "(Don't Fear) The Reaper",
/// "(I Can't Get No) Satisfaction" — and throwing those away would merge
/// genuinely different songs.
final RegExp _releaseNoise = RegExp(
  r'[\(\[]\s*('
  r'remaster(ed)?|re-?master(ed)?|'
  r'\d{4}\s+remaster(ed)?|remaster(ed)?\s+\d{4}|'
  r'deluxe|deluxe\s+edition|expanded|expanded\s+edition|'
  // Release formats. Bracketed only, so a song actually called
  // "Single" is untouched.
  r'single|ep|lp|maxi\s+single|digital\s+single|'
  r'bonus\s+track|bonus|explicit|clean|'
  r'album\s+version|single\s+version|radio\s+edit|radio\s+version|'
  r'original\s+mix|extended\s+mix|'
  r'mono|stereo|hd|hq|lyrics|lyric\s+video|'
  r'official\s+(music\s+)?video|official\s+audio|audio|'
  r'full\s+album|free\s+download'
  r')\s*[\)\]]',
  caseSensitive: false,
);

/// Featured-artist credits, which belong to the artist field and not the
/// title — but end up in both, inconsistently.
final RegExp _featuring = RegExp(
  r'\s*[\(\[]?\s*(feat\.?|ft\.?|featuring|w/|with)\s+[^\)\]]*[\)\]]?\s*$',
  caseSensitive: false,
);

/// A leading track number, as filenames carry it: "01 ", "01. ", "01 - ".
final RegExp _leadingTrackNumber = RegExp(r'^\s*\d{1,3}\s*[-._)]?\s+');

/// Punctuation that *joins* rather than separates, and so should vanish
/// rather than become a space.
///
/// "N.W.A." must normalise to "nwa", not "n w a" — an initialism is one
/// word. Apostrophes behave the same way: "Don't" is "dont", not "don t".
/// Both straight and curly apostrophes, since taggers disagree.
final RegExp _joiners = RegExp(r"[.'\u2019\u02bc`]");

/// Everything else that is not a letter, digit or space. These really do
/// separate words, so they become spaces.
final RegExp _separators = RegExp(r"[^\p{L}\p{N} ]", unicode: true);

final RegExp _whitespace = RegExp(r'\s+');

/// Reduces a name to the form worth comparing.
///
/// Order matters and is not arbitrary: featured-artist credits are
/// stripped before punctuation, because the brackets around them are the
/// thing that identifies them. Release noise goes before that for the
/// same reason.
///
/// This is lossy on purpose. It is only ever used for *comparison* — the
/// original string is what gets written to the tag and the filename.
String normaliseForMatching(String raw) {
  var s = raw.toLowerCase().trim();

  s = s.replaceAll(_releaseNoise, ' ');
  s = s.replaceAll(_featuring, ' ');
  s = s.replaceFirst(_leadingTrackNumber, '');

  // Spelled-out and symbolic forms of the same thing. "Earth, Wind & Fire"
  // and "Earth Wind and Fire" are one band.
  s = s.replaceAll('&', ' and ');
  s = s.replaceAll('+', ' and ');

  // Before punctuation goes, because the comma is what identifies the
  // form. Strip it afterwards and "Beatles, The" has already become
  // "beatles the", which no longer matches the rule.
  s = s.replaceFirst(_trailingArticle, '');

  s = s.replaceAll(_joiners, '');
  s = s.replaceAll(_separators, ' ');
  s = s.replaceAll(_whitespace, ' ').trim();

  s = s.replaceFirst(_leadingArticle, '');

  return s.trim();
}

/// How alike two names are once the noise is gone.
///
/// This is the function the rest of the app should use. Comparing raw
/// strings finds only the matches that were never a problem.
double nameSimilarity(String a, String b) =>
    similarity(normaliseForMatching(a), normaliseForMatching(b));

/// Above this, two names are treated as the same thing.
///
/// 0.86 was chosen against a real collection rather than picked from the
/// air: it catches "Nujabes / Fat Jon" vs "nujabes_fat_jon" and the
/// endless casing and punctuation variants, while leaving "Lana Del Rey"
/// and "Lana Del Ray" — which *is* a real pair of spellings, one of them
/// wrong, and therefore something to flag — comfortably above, and
/// genuinely different short names like "Muse" and "Mute" below.
const double kSameNameThreshold = 0.86;

/// Low enough to be worth a human look, high enough not to be noise.
const double kSuggestNameThreshold = 0.72;

/// Whether two names should be treated as the same.
bool looksLikeSameName(String a, String b) =>
    nameSimilarity(a, b) >= kSameNameThreshold;

/// Groups names that look like variants of each other.
///
/// Single-link clustering: A joins a group if it matches *any* member.
/// That is the right shape for spelling variants, which form chains —
/// "Beatles" matches "The Beatles" matches "The Beatles " — even where
/// the two ends of the chain would not match each other directly.
///
/// It is also the shape that can over-merge if the threshold is too low,
/// which is why nothing here acts on a grouping without showing it first.
///
/// Returns groups of the original strings, largest first. Names with no
/// partner come back as groups of one, so the caller always sees every
/// input exactly once.
List<List<String>> groupSimilarNames(
  Iterable<String> names, {
  double threshold = kSameNameThreshold,
}) {
  // Deduplicate exact repeats first, keeping the first spelling seen.
  final unique = <String>[];
  final seen = <String>{};
  for (final n in names) {
    if (seen.add(n)) unique.add(n);
  }

  final normalised = [for (final n in unique) normaliseForMatching(n)];

  // Union-find over the index space. Cheaper and clearer than building an
  // adjacency list for what is only ever asked "are these connected".
  final parent = List<int>.generate(unique.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void union(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[rb] = ra;
  }

  for (var i = 0; i < unique.length; i++) {
    for (var j = i + 1; j < unique.length; j++) {
      final a = normalised[i], b = normalised[j];
      final longest = math.max(a.length, b.length);
      if (longest == 0) {
        union(i, j);
        continue;
      }
      // Turn the similarity threshold into an edit budget, so the
      // early-abort version can be used. This is the whole reason
      // all-pairs is affordable at collection scale.
      final budget = ((1 - threshold) * longest).floor();
      if (levenshteinWithin(a, b, budget) <= budget) union(i, j);
    }
  }

  final groups = <int, List<String>>{};
  for (var i = 0; i < unique.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(unique[i]);
  }

  // Sorted inside each group as well as between them. Without this the
  // members come back in input order, which makes both the group's first
  // element and therefore the whole list's order depend on how the
  // directory happened to be walked.
  for (final g in groups.values) {
    g.sort();
  }

  final out = groups.values.toList()
    ..sort((a, b) {
      final bySize = b.length.compareTo(a.length);
      // Then alphabetically, so the output is stable between runs and a
      // diff of two reports is readable.
      return bySize != 0 ? bySize : a.first.compareTo(b.first);
    });
  return out;
}

/// The spelling to standardise a group on.
///
/// The most common one wins, because a collection that has a name 40
/// times one way and twice another is telling you which is intended. Ties
/// go to the longest, on the reasoning that "The Beatles" carries more
/// information than "Beatles" and dropping the article is the lossy
/// direction; then alphabetically, so the choice is deterministic.
String canonicalName(Iterable<String> variants) {
  final counts = <String, int>{};
  for (final v in variants) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) return byCount;
      final byLength = b.key.length.compareTo(a.key.length);
      return byLength != 0 ? byLength : a.key.compareTo(b.key);
    });
  return entries.first.key;
}
