import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/core/guess.dart';
import 'package:mp3sorter/core/tags.dart';

void main() {
  // Names taken from a real collection.
  group('guessFromFilename', () {
    test('"NN Title" from an album folder', () {
      final g = guessFromFilename("05 Warrior's Dance - Future Funk Squad's 'Rave Soldier' Mix.mp3");
      expect(g.trackNumber, 5);
      // A spaced dash after a track number is ambiguous; it reads as
      // artist - title, which the folder candidate then corrects.
      expect(g.artist, "Warrior's Dance");
    });

    test('snake case with a bare dash separator', () {
      final g = guessFromFilename('07_shinedown-if_you_only_knew.mp3');
      expect(g.trackNumber, 7);
      expect(g.artist, 'Shinedown');
      expect(g.title, 'If You Only Knew');
    });

    test('disc-track prefix', () {
      final g = guessFromFilename('1-02_Rammstein-Mein_Teil.mp3');
      expect(g.disc, 1);
      expect(g.trackNumber, 2);
      expect(g.artist, 'Rammstein');
      expect(g.title, 'Mein Teil');
    });

    test('video noise is removed', () {
      final g = guessFromFilename('The Secret Sisters - Hand Over My Heart [Official Video].mp3');
      expect(g.artist, 'The Secret Sisters');
      expect(g.title, 'Hand Over My Heart');
    });

    test('download-site suffixes are removed', () {
      final g = guessFromFilename('big_data_dangerous_feat_joywave_official_music_video_cbr_256k.mp3');
      expect(g.title, isNot(contains('256')));
      expect(g.title!.toLowerCase(), isNot(contains('official')));
    });

    test('a bare number is a track with no title', () {
      final g = guessFromFilename('24.mp3');
      expect(g.title, '24');
    });

    test('mixed case is left as the owner spelled it', () {
      final g = guessFromFilename('deadmau5 - Strobe.flac');
      expect(g.artist, 'deadmau5');
      expect(g.title, 'Strobe');
    });

    test('a hyphen inside a spaced name is not a separator', () {
      final g = guessFromFilename('Jay-Z Song.mp3');
      expect(g.artist, isNull);
      expect(g.title, 'Jay-Z Song');
    });
  });

  group('cleanFolderName', () {
    test('year in brackets', () {
      expect(cleanFolderName('[2005] Wolfmother'), ('Wolfmother', 2005));
    });
    test('leading year, kebab words and a trailing id', () {
      expect(cleanFolderName('2019_norman-fucking-rockwell_218434'),
          ('Norman Fucking Rockwell', 2019));
    });
    test('snake case artist', () {
      expect(cleanFolderName('blue_oyster_cult'), ('Blue Oyster Cult', null));
    });
    test('generic folders say nothing', () {
      expect(cleanFolderName('0_unsorted').$1, isNull);
      expect(cleanFolderName('Music').$1, isNull);
    });
  });

  group('guessFromFolders', () {
    test('artist/album above the file', () {
      final g = guessFromFolders('/m/_sorted/Mastodon/The Hunter/11 Spectrelight.mp3', '/m');
      expect(g.album, 'The Hunter');
      expect(g.artist, 'Mastodon');
    });
    test('a file directly in the chosen folder has no folder guess', () {
      final g = guessFromFolders('/m/song.mp3', '/m');
      expect(g.album, isNull);
      expect(g.artist, isNull);
    });
    test('the chosen folder itself is never the album', () {
      final g = guessFromFolders('/m/Album/song.mp3', '/m/Album');
      expect(g.album, isNull);
    });
  });

  group('offlineCandidates', () {
    test('filename and folders both offered, folders ranked higher', () {
      final c = offlineCandidates(
          filePath: '/m/rammstein/greatest_hits/1-02_Rammstein-Mein_Teil.mp3',
          root: '/m');
      expect(c.map((x) => x.source),
          [CandidateSource.filename, CandidateSource.folder]);
      final folder = c.last.tags;
      expect(folder.album, 'Greatest Hits');
      expect(folder.title, 'Mein Teil');
      expect(folder.trackNumber, 2);
      expect(c.last.score, greaterThan(c.first.score));
    });
  });
}
