/// Cover art: where it comes from, and when it must not be guessed.
///
/// Two rules carry most of the weight here, and both are about doing
/// nothing rather than doing something wrong. A cover already on a file
/// or already in a folder is never replaced, and a lookup that is not
/// confident writes nothing — because a wrong cover embedded in forty
/// files is worse than forty files with no cover, and far harder to
/// notice.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp3sorter/artwork.dart';
import 'package:mp3sorter/cover_art.dart';
import 'package:mp3sorter/plan.dart';
import 'package:mp3sorter/track.dart';

Track t(String path, {String? artist, String? album, String? title}) => Track(
      path: path,
      sizeBytes: 1000,
      artist: artist,
      album: album,
      title: title,
      bitrateKbps: 192,
    );

/// Smallest thing that sniffs as a JPEG.
Uint8List jpeg([int size = 64]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(size, 0x11)]);

Uint8List png([int size = 64]) => Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(size, 0x22)]);

void main() {
  group('grouping albums', () {
    test('one album with a bare track is filled from its sibling', () {
      final tracks = [
        t('/m/A/01.mp3', artist: 'Wolfmother', album: 'Cosmic Egg', title: 'a'),
        t('/m/A/02.mp3', artist: 'Wolfmother', album: 'Cosmic Egg', title: 'b'),
      ];
      final albums = planArtwork(
        tracks,
        embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums, hasLength(1));
      expect(albums.single.source, ArtSource.sibling);
      expect(albums.single.sourcePath, '/m/A/01.mp3');
      expect(albums.single.tracksMissingArt.map((x) => x.path), ['/m/A/02.mp3']);
    });

    test('an album where everything has art is left alone', () {
      final tracks = [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')];
      final albums = planArtwork(
        tracks,
        embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums.single.source, ArtSource.alreadyPresent);
      expect(artActions(albums), isEmpty);
    });

    test('two spellings of one album are one album', () {
      // The reason the normalisation is reused here: tagged twice, the
      // record would otherwise be two half-covered albums, and the
      // tagged-once half would never donate to the other.
      final tracks = [
        t('/m/A/01.mp3', artist: 'BABYMETAL', album: 'Metal Resistance', title: 'a'),
        t('/m/A/02.mp3', artist: 'Babymetal', album: 'metal resistance', title: 'b'),
      ];
      final albums = planArtwork(
        tracks,
        embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums, hasLength(1));
      expect(albums.single.source, ArtSource.sibling);
    });

    test('a track with no album is not invented into one', () {
      // There is nothing to look up and nowhere to put a cover: a
      // loose single's "album" would be itself.
      final albums = planArtwork(
        [t('/m/loose.mp3', artist: 'X', title: 'a')],
        embeddedArt: const {},
        folderImages: const {},
      );
      expect(albums, isEmpty);
    });

    test('an album with no artist is not looked up', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', album: 'Some Record', title: 'a')],
        embeddedArt: const {},
        folderImages: const {},
      );
      expect(albums, isEmpty);
    });

    test('a scattered album puts its cover where most of it lives', () {
      final tracks = [
        t('/m/here/01.mp3', artist: 'X', album: 'Y', title: 'a'),
        t('/m/here/02.mp3', artist: 'X', album: 'Y', title: 'b'),
        t('/m/stray/03.mp3', artist: 'X', album: 'Y', title: 'c'),
      ];
      final albums = planArtwork(
        tracks,
        embeddedArt: const {},
        folderImages: const {},
      );
      expect(albums.single.folder, '/m/here');
    });

    test('a JPEG donor is preferred over a PNG one', () {
      // Only because the written cover file is named after it, and
      // cover.jpg is what every player looks for first.
      final tracks = [
        t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
        t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
        t('/m/A/03.mp3', artist: 'X', album: 'Y', title: 'c'),
      ];
      final albums = planArtwork(
        tracks,
        embeddedArt: {'/m/A/01.mp3': 'image/png', '/m/A/02.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums.single.sourcePath, '/m/A/02.mp3');
      expect(albums.single.coverFileName, 'cover.jpg');
    });

    test('a PNG-only album gets a cover.png, not a lying cover.jpg', () {
      final albums = planArtwork(
        [
          t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
          t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
        ],
        embeddedArt: {'/m/A/01.mp3': 'image/png'},
        folderImages: const {},
      );
      expect(albums.single.coverFileName, 'cover.png');
    });

    test('a folder image is used when no track has art', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')],
        embeddedArt: const {},
        folderImages: const {'/m/A': '/m/A/folder.jpg'},
      );
      expect(albums.single.source, ArtSource.folderImage);
      expect(albums.single.sourcePath, '/m/A/folder.jpg');
    });

    test('nothing anywhere means a lookup is needed', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')],
        embeddedArt: const {},
        folderImages: const {},
      );
      expect(albums.single.source, ArtSource.needsLookup);
      expect(albums.single.needsNetwork, isTrue);
    });

    test('the order is stable across runs', () {
      final tracks = [
        for (var i = 0; i < 6; i++)
          t('/m/$i/01.mp3', artist: 'A$i', album: 'B$i', title: 'x'),
      ];
      final first = planArtwork(tracks,
          embeddedArt: const {}, folderImages: const {});
      final again = planArtwork(tracks.reversed.toList(),
          embeddedArt: const {}, folderImages: const {});
      expect(first.map((a) => a.album), again.map((a) => a.album));
    });
  });

  group('the summary', () {
    test('it counts files, not albums, for what can be fixed offline', () {
      final albums = planArtwork(
        [
          t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
          t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
          t('/m/A/03.mp3', artist: 'X', album: 'Y', title: 'c'),
          t('/m/B/01.mp3', artist: 'P', album: 'Q', title: 'd'),
        ],
        embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      final s = summariseArtwork(albums);
      expect(s.albums, 2);
      expect(s.filesMissing, 3, reason: 'two in A, one in B');
      expect(s.filesFixableOffline, 2, reason: 'only A has a donor');
      expect(s.needLookup, 1);
      expect(s.anythingOffline, isTrue);
    });

    test('a collection that needs nothing says so', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')],
        embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(summariseArtwork(albums).allDone, isTrue);
    });
  });

  group('picking the cover out of a folder', () {
    test('cover beats everything', () {
      expect(
        pickFolderCover(['/a/back.jpg', '/a/scan1.jpg', '/a/cover.jpg']),
        '/a/cover.jpg',
      );
    });

    test('the preference order is honoured', () {
      expect(pickFolderCover(['/a/front.jpg', '/a/folder.jpg']),
          '/a/folder.jpg');
    });

    test('a suffix on a known name still reads as a cover', () {
      expect(pickFolderCover(['/a/cover_500.jpg']), '/a/cover_500.jpg');
    });

    test('an unrecognised name is used only as a last resort', () {
      expect(pickFolderCover(['/a/scan001.jpg']), '/a/scan001.jpg');
      expect(pickFolderCover(['/a/scan001.jpg', '/a/art.png']), '/a/art.png');
    });

    test('a non-image is never picked', () {
      expect(pickFolderCover(['/a/cover.txt', '/a/cover.pdf']), isNull);
    });

    test('an empty folder is nothing, not a crash', () {
      expect(pickFolderCover(const []), isNull);
    });
  });

  group('turning albums into actions', () {
    List<AlbumArt> twoTrackAlbumWithDonor() => planArtwork(
          [
            t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
            t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
          ],
          embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
          folderImages: const {},
        );

    test('both halves of the chosen behaviour: a cover file and an embed', () {
      final actions = artActions(twoTrackAlbumWithDonor());
      expect(
        actions.map((a) => '${a.kind.name} ${a.path}'),
        ['writeCover /m/A/cover.jpg', 'embedArt /m/A/02.mp3'],
      );
      expect(actions.every((a) => a.artFrom == '/m/A/01.mp3'), isTrue);
    });

    test('an existing cover file is never written over', () {
      final actions = artActions(
        twoTrackAlbumWithDonor(),
        existingCovers: {'/m/a/cover.jpg'},
      );
      expect(actions.map((a) => a.kind), [ActionKind.embedArt],
          reason: 'compared case-insensitively — FAT cards shout');
    });

    test('a folder that already holds an image gets no second one', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')],
        embeddedArt: const {},
        folderImages: const {'/m/A': '/m/A/albumart.jpg'},
      );
      final actions = artActions(albums);
      expect(actions.map((a) => a.kind), [ActionKind.embedArt]);
    });

    test('an album still needing a lookup produces nothing', () {
      final albums = planArtwork(
        [t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a')],
        embeddedArt: const {},
        folderImages: const {},
      );
      expect(artActions(albums), isEmpty);
    });

    test('either half can be switched off', () {
      expect(
        artActions(twoTrackAlbumWithDonor(), writeCoverFiles: false)
            .map((a) => a.kind),
        [ActionKind.embedArt],
      );
      expect(
        artActions(twoTrackAlbumWithDonor(), embedInFiles: false)
            .map((a) => a.kind),
        [ActionKind.writeCover],
      );
    });

    test('a folder holding two albums gets no cover file', () {
      // Flat `artist/` folders with several records loose in them are
      // common, and there is no single right cover.jpg for one. Writing
      // one means every player showing the wrong sleeve for the other
      // album — a confident, visible error, where doing nothing is just
      // a gap. Embedding still happens: that is per file.
      final albums = planArtwork(
        [
          t('/m/artist/a1.mp3', artist: 'X', album: 'First', title: 'a'),
          t('/m/artist/a2.mp3', artist: 'X', album: 'First', title: 'b'),
          t('/m/artist/b1.mp3', artist: 'X', album: 'Second', title: 'c'),
          t('/m/artist/b2.mp3', artist: 'X', album: 'Second', title: 'd'),
        ],
        embeddedArt: {'/m/artist/a1.mp3': 'image/jpeg',
                      '/m/artist/b1.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums.every((a) => a.folderIsShared), isTrue);
      final actions = artActions(albums);
      expect(actions.every((a) => a.kind == ActionKind.embedArt), isTrue);
      expect(actions, hasLength(2));
    });

    test('a folder with one album in it does get a cover file', () {
      final albums = planArtwork(
        [
          t('/m/artist/album/01.mp3', artist: 'X', album: 'Only', title: 'a'),
          t('/m/artist/album/02.mp3', artist: 'X', album: 'Only', title: 'b'),
        ],
        embeddedArt: {'/m/artist/album/01.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      expect(albums.single.folderIsShared, isFalse);
      expect(artActions(albums).map((a) => a.kind),
          [ActionKind.writeCover, ActionKind.embedArt]);
    });

    test('two albums sharing a folder can never collide on one cover name', () {
      // The latent failure this rules out: both albums planning
      // `cover.jpg` in the same folder, which validatePlan reports as
      // "planned twice" and which blocks the entire run.
      final albums = planArtwork(
        [
          t('/m/flat/a.mp3', artist: 'X', album: 'One', title: 'a'),
          t('/m/flat/a2.mp3', artist: 'X', album: 'One', title: 'a2'),
          t('/m/flat/b.mp3', artist: 'Y', album: 'Two', title: 'b'),
          t('/m/flat/b2.mp3', artist: 'Y', album: 'Two', title: 'b2'),
        ],
        embeddedArt: {'/m/flat/a.mp3': 'image/jpeg', '/m/flat/b.mp3': 'image/jpeg'},
        folderImages: const {},
      );
      final plan = Plan(
        moves: const [],
        retags: const [],
        trashes: const [],
        art: artActions(albums),
        artistMerges: const {},
        unsortable: const [],
      );
      expect(validatePlan(plan), isEmpty);
    });

    test('every action says where its cover came from', () {
      // The review list is the only place a wrong source gets caught.
      for (final a in artActions(twoTrackAlbumWithDonor())) {
        expect(a.reason, contains('another track'));
      }
    });
  });

  group('art and moves must not share a run', () {
    test('a plan holding both is refused', () {
      // A cover is written beside the folder a file is in now, and a
      // move changes which folder that is. Rather than guess which the
      // person meant, the two are kept to separate runs.
      final plan = Plan(
        moves: [
          const PlannedAction(
            kind: ActionKind.move,
            path: '/m/A/01.mp3',
            targetPath: '/sorted/X/Y/01 a.mp3',
          ),
        ],
        retags: const [],
        trashes: const [],
        art: artActions(planArtwork(
          [
            t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
            t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
          ],
          embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
          folderImages: const {},
        )),
        artistMerges: const {},
        unsortable: const [],
        occupiedPaths: {'/m/a/01.mp3', '/m/a/02.mp3'},
      );
      expect(
        validatePlan(plan).map((p) => p.message),
        contains(contains('cannot be applied in one run')),
      );
    });

    test('art on its own is fine', () {
      final plan = Plan(
        moves: const [],
        retags: const [],
        trashes: const [],
        art: artActions(planArtwork(
          [
            t('/m/A/01.mp3', artist: 'X', album: 'Y', title: 'a'),
            t('/m/A/02.mp3', artist: 'X', album: 'Y', title: 'b'),
          ],
          embeddedArt: {'/m/A/01.mp3': 'image/jpeg'},
          folderImages: const {},
        )),
        artistMerges: const {},
        unsortable: const [],
      );
      expect(validatePlan(plan), isEmpty);
      expect(plan.actionCount, 2);
    });

    test('withArt leaves the rest of the plan alone', () {
      final base = Plan(
        moves: const [],
        retags: const [],
        trashes: const [],
        artistMerges: const {'Muse': ['muse']},
        unsortable: const [],
        occupiedPaths: const {'/m/a.mp3'},
      );
      final withArt = base.withArt([
        const PlannedAction(
            kind: ActionKind.writeCover, path: '/m/A/cover.jpg'),
      ]);
      expect(withArt.artistMerges, base.artistMerges);
      expect(withArt.occupiedPaths, base.occupiedPaths);
      expect(withArt.art, hasLength(1));
    });
  });

  group('sniffing an image', () {
    test('it reads the bytes rather than believing a label', () {
      expect(sniffImageType(jpeg()), 'image/jpeg');
      expect(sniffImageType(png()), 'image/png');
    });

    test('WEBP is recognised but not embeddable', () {
      final webp = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0, 0, 0, 0,
        ...'WEBP'.codeUnits,
        ...List.filled(16, 0),
      ]);
      expect(sniffImageType(webp), 'image/webp');
      // Deliberate: ID3 will carry it and a car stereo from 2014 will
      // show nothing, which looks exactly like the problem being fixed.
      expect(kEmbeddableTypes, isNot(contains('image/webp')));
    });

    test('something that is not an image at all is nothing', () {
      expect(sniffImageType(Uint8List.fromList(utf8.encode('<html>404</html>'))),
          isNull);
      expect(sniffImageType(Uint8List(4)), isNull, reason: 'too short to tell');
    });
  });

  group('extensions', () {
    test('known image extensions map to types', () {
      expect(mimeTypeForExtension('/a/x.JPEG'), 'image/jpeg');
      expect(mimeTypeForExtension('/a/x.png'), 'image/png');
      expect(mimeTypeForExtension('/a/x.mp3'), isNull);
    });
  });
}
