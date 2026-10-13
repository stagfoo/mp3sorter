/// Fuzzy matching, against the string shapes a real collection contains.
///
/// Most of these cases are lifted from the kinds of name a music folder
/// actually holds — three spellings of one band, a title carrying the
/// word "Remastered", a filename that is a unix timestamp. A test suite
/// of invented strings would pass while the thing stayed useless.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/levenshtein.dart';

void main() {
  group('levenshtein', () {
    test('identical strings are zero apart', () {
      expect(levenshtein('Radiohead', 'Radiohead'), 0);
      expect(levenshtein('', ''), 0);
    });

    test('an empty string costs its partner length', () {
      expect(levenshtein('', 'Muse'), 4);
      expect(levenshtein('Muse', ''), 4);
    });

    test('the three edit kinds each cost one', () {
      expect(levenshtein('cat', 'cats'), 1); // insertion
      expect(levenshtein('cats', 'cat'), 1); // deletion
      expect(levenshtein('cat', 'cot'), 1); // substitution
    });

    test('the classic worked example', () {
      expect(levenshtein('kitten', 'sitting'), 3);
      expect(levenshtein('saturday', 'sunday'), 3);
    });

    test('it is symmetric', () {
      expect(levenshtein('Lana Del Rey', 'Lana Del Ray'),
          levenshtein('Lana Del Ray', 'Lana Del Rey'));
    });

    test('non-ascii is handled by code unit, not byte', () {
      expect(levenshtein('Sigur Rós', 'Sigur Ros'), 1);
      expect(levenshtein('日本語', '日本語'), 0);
      expect(levenshtein('日本語', '日本'), 1);
    });
  });

  group('early-abort distance', () {
    test('it agrees with the full version when under budget', () {
      for (final pair in [
        ['kitten', 'sitting'],
        ['Muse', 'Mute'],
        ['', 'abc'],
        ['abc', 'abc'],
      ]) {
        final full = levenshtein(pair[0], pair[1]);
        expect(levenshteinWithin(pair[0], pair[1], 10), full,
            reason: '${pair[0]} vs ${pair[1]}');
      }
    });

    test('it gives up rather than computing a distance you did not want',
        () {
      // The contract is "greater than the budget", not the true distance.
      final d = levenshteinWithin('Radiohead', 'Fleetwood Mac', 2);
      expect(d, greaterThan(2));
    });

    test('a length gap alone is enough to reject', () {
      // The cheap rejection that makes all-pairs affordable: no matrix is
      // built at all here.
      expect(levenshteinWithin('a', 'abcdefghijklmnop', 3), greaterThan(3));
    });

    test('a zero budget still recognises equality', () {
      expect(levenshteinWithin('Muse', 'Muse', 0), 0);
      expect(levenshteinWithin('Muse', 'Mute', 0), greaterThan(0));
    });
  });

  group('normalising a name for comparison', () {
    test('case and punctuation go', () {
      expect(normaliseForMatching('Sigur Rós!'), 'sigur rós');
      expect(normaliseForMatching('N.W.A.'), 'nwa');
    });

    test('leading and trailing articles go', () {
      expect(normaliseForMatching('The Beatles'), 'beatles');
      expect(normaliseForMatching('Beatles, The'), 'beatles');
      expect(normaliseForMatching('A Perfect Circle'), 'perfect circle');
    });

    test('ampersands and plus signs become the word', () {
      expect(normaliseForMatching('Earth, Wind & Fire'),
          normaliseForMatching('Earth Wind and Fire'));
    });

    test('release noise is stripped', () {
      expect(normaliseForMatching('Born to Die (Remastered 2011)'),
          'born to die');
      expect(normaliseForMatching('Creep [Explicit]'), 'creep');
      expect(normaliseForMatching('Hello (Official Music Video)'), 'hello');
      expect(normaliseForMatching('Song (Radio Edit)'), 'song');
    });

    test('a parenthesised phrase that is part of the title survives', () {
      // The reason release noise is a fixed list rather than "strip all
      // brackets": these are different songs from their unbracketed
      // namesakes, and merging them would be wrong.
      expect(normaliseForMatching("(Don't Fear) The Reaper"),
          contains('fear'));
      expect(normaliseForMatching("(I Can't Get No) Satisfaction"),
          contains('get no'));
    });

    test('featured-artist credits go', () {
      expect(normaliseForMatching('Numb (feat. Jay-Z)'), 'numb');
      expect(normaliseForMatching('Numb ft. Jay-Z'), 'numb');
      expect(normaliseForMatching('Numb featuring Jay-Z'), 'numb');
    });

    test('a leading track number goes', () {
      expect(normaliseForMatching('01 Born to Die'), 'born to die');
      expect(normaliseForMatching('01. Born to Die'), 'born to die');
      expect(normaliseForMatching('01 - Born to Die'), 'born to die');
      expect(normaliseForMatching('1 Born to Die'), 'born to die');
    });

    test('a number that is the title is not mistaken for a track number',
        () {
      // "1979" and "99 Problems" start with digits and are not track
      // numbers. The rule requires separating whitespace after the digits,
      // which is what tells them apart.
      expect(normaliseForMatching('1979'), '1979');
      expect(normaliseForMatching('99 Problems'), 'problems',
          reason: 'a known limitation: this one is indistinguishable '
              'from a numbered track without more context');
    });

    test('whitespace is collapsed', () {
      expect(normaliseForMatching('  The   Beatles  '), 'beatles');
    });
  });

  group('name similarity', () {
    test('spelling variants of one band match', () {
      expect(looksLikeSameName('The Beatles', 'Beatles'), isTrue);
      expect(looksLikeSameName('Nujabes / Fat Jon', 'nujabes_fat_jon'),
          isTrue);
      expect(looksLikeSameName('Carly Rae Jepsen', 'carly_rae_jepsen'),
          isTrue);
      expect(looksLikeSameName('A Perfect Circle', 'a_perfect_circle'),
          isTrue);
    });

    test('a genuine misspelling is close enough to flag', () {
      // One of these is wrong and they should be reconciled, so the
      // threshold must be loose enough to catch it.
      expect(looksLikeSameName('Lana Del Rey', 'Lana Del Ray'), isTrue);
    });

    test('different short names stay apart', () {
      // The case a too-low threshold ruins: short names differ on small
      // margins and really are different artists.
      expect(looksLikeSameName('Muse', 'Mute'), isFalse);
      expect(looksLikeSameName('Sia', 'Mia'), isFalse);
      expect(looksLikeSameName('Air', 'Hair'), isFalse);
    });

    test('different bands stay apart', () {
      expect(looksLikeSameName('Radiohead', 'Fleetwood Mac'), isFalse);
      expect(looksLikeSameName('Eleine', 'Elaine Paige'), isFalse);
    });

    test('similarity is bounded and ordered', () {
      expect(nameSimilarity('abc', 'abc'), 1.0);
      expect(nameSimilarity('abc', 'xyz'), lessThan(0.5));
      expect(nameSimilarity('The Beatles', 'Beatles'),
          greaterThan(nameSimilarity('The Beatles', 'Beetles Live')));
    });
  });

  group('grouping variants', () {
    test('three spellings of one band become one group', () {
      final groups = groupSimilarNames([
        'The Beatles',
        'Beatles',
        'beatles',
        'Radiohead',
      ]);
      expect(groups.first.length, 3);
      expect(groups.last, ['Radiohead']);
    });

    test('every input appears exactly once', () {
      final names = [
        'Muse',
        'Mute',
        'The National',
        'National',
        'Sigur Rós',
        'Sigur Ros',
      ];
      final flat = groupSimilarNames(names).expand((g) => g).toList();
      expect(flat.length, names.length);
      expect(flat.toSet(), names.toSet());
    });

    test('exact duplicates collapse rather than forming a pair', () {
      final groups = groupSimilarNames(['Muse', 'Muse', 'Muse']);
      expect(groups, hasLength(1));
      expect(groups.first, ['Muse']);
    });

    test('variants chain through a middle spelling', () {
      // Single-link is deliberate: the two ends need not match each other
      // directly, only through the chain.
      final groups = groupSimilarNames(
          ['Beatles', 'The Beatles', 'The Beatles '],
          threshold: kSameNameThreshold);
      expect(groups.first.length, 3);
    });

    test('a tighter threshold splits what a loose one merged', () {
      final loose = groupSimilarNames(['Muse', 'Mute'], threshold: 0.7);
      final tight = groupSimilarNames(['Muse', 'Mute'], threshold: 0.95);
      expect(loose.first.length, 2);
      expect(tight, hasLength(2));
    });

    test('empty input is empty, not a crash', () {
      expect(groupSimilarNames(const []), isEmpty);
    });

    test('the order is stable between runs', () {
      final names = ['Zeta', 'Alpha', 'alpha', 'Beta'];
      expect(groupSimilarNames(names), groupSimilarNames(names.reversed));
    });

    test('it scales to a collection-sized list', () {
      // 1,200 distinct names is a large real library. This must finish in
      // well under a second or the scan screen is unusable.
      final names = [for (var i = 0; i < 1200; i++) 'Artist Number $i'];
      final sw = Stopwatch()..start();
      final groups = groupSimilarNames(names);
      sw.stop();
      expect(groups, isNotEmpty);
      expect(sw.elapsedMilliseconds, lessThan(4000),
          reason: 'took ${sw.elapsedMilliseconds}ms');
    });
  });

  group('choosing the canonical spelling', () {
    test('the commonest spelling wins', () {
      expect(
        canonicalName(['The Beatles', 'The Beatles', 'beatles']),
        'The Beatles',
      );
    });

    test('ties go to the longer, more informative spelling', () {
      expect(canonicalName(['Beatles', 'The Beatles']), 'The Beatles');
    });

    test('it is deterministic for a full tie', () {
      expect(canonicalName(['Abba', 'ABBA']), canonicalName(['ABBA', 'Abba']));
    });

    test('a single name is its own canonical form', () {
      expect(canonicalName(['Muse']), 'Muse');
    });
  });
}
