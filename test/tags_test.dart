import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/tag_io.dart';
import 'package:mp3sorter/core/tags.dart';

void main() {
  group('TagSet', () {
    test('blank and whitespace are the same as unset', () {
      expect(const TagSet(title: '  ', year: 0), TagSet.empty);
      expect(const TagSet(title: ' A '), const TagSet(title: 'A'));
    });

    test('a chip fills what it knows and keeps the rest', () {
      const draft = TagSet(title: 'Mine', trackNumber: 3, genre: 'Rock');
      final out = draft.overlaidWith(const TagSet(title: 'Theirs', album: 'LP'));
      expect(out, const TagSet(title: 'Theirs', album: 'LP', trackNumber: 3, genre: 'Rock'));
    });

    test('album fields leave the per-track ones out', () {
      const t = TagSet(
          artist: 'A', title: 'T', album: 'Al', albumArtist: 'AA', year: 1999, trackNumber: 4, genre: 'G');
      expect(t.albumFields(), const TagSet(album: 'Al', albumArtist: 'AA', year: 1999, genre: 'G'));
    });

    test('json round trip', () {
      const t = TagSet(artist: 'A', year: 2001, trackNumber: 2);
      expect(TagSet.fromJson(t.toJson()), t);
    });
  });

  test('dedupeCandidates keeps the first of each and drops empties', () {
    const a = Candidate(label: 'one', source: CandidateSource.musicBrainz, tags: TagSet(title: 'X'));
    const b = Candidate(label: 'two', source: CandidateSource.musicBrainz, tags: TagSet(title: ' X '));
    const e = Candidate(label: 'empty', source: CandidateSource.filename, tags: TagSet.empty);
    expect(dedupeCandidates([a, e, b]).map((c) => c.label), ['one']);
  });

  group('changedFields', () {
    test('only what differs is written', () {
      const before = TagSet(title: 'T', genre: 'Jazz', year: 1998);
      const wanted = TagSet(title: 'T', genre: 'Jazz', year: 1998, album: 'New');
      expect(changedFields(before, wanted), const TagSet(album: 'New'));
    });
    test('a blank wanted field never clears one', () {
      expect(changedFields(const TagSet(title: 'T'), TagSet.empty), TagSet.empty);
    });
  });

  test('extensions', () {
    expect(extensionOf('/a/b.MP3'), '.mp3');
    expect(extensionOf('/a.b/c'), '');
    expect(extensionOf('/a/.hidden'), '');
    expect(canWrite('/x.opus'), isFalse);
    expect(isAudioFile('/x.opus'), isTrue);
    expect(canWrite('/x.flac'), isTrue);
  });
}
