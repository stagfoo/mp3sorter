# mp3sorter

Swipe through a folder of music, one card per track, and fix the tags as
you go.

| Gesture | Key | What happens |
| --- | --- | --- |
| Swipe **right** | → / Enter | Save the tags on the card |
| Swipe **left** | ← | Skip — the file is not touched |
| Swipe **up** | ↑ | Save, then give the rest of the folder this card's album, album artist, year, genre and cover |
| | ↓ / Backspace | Bring back the last skipped track |
| | Space | Play / pause |
| | 1–9 | Pick a suggestion |
| | E | Show / hide the fields |
| | Ctrl+Z | Undo the last save (a whole batch at once) |

Each card plays the track (at medium volume, with a scrubber) so you can
hear what you are tagging. Under it are **suggestions** — what the file is
tagged as now, what its filename and folders say, and matches from
MusicBrainz — and the **fields**, editable inline.

Version 1.0.13 and earlier were a different app (bulk renaming, duplicate
finding, bitrate reports). This replaces it.

## What it will not do to your files

The previous app left a phone library with missing covers and damaged
tags. Everything here is built against that:

- **Only fields you changed are written.** Re-writing a field with what it
  already says is not harmless: a genre of `Jazz/Blues/Rock` reads back as
  `Jazz`, and writing `Jazz` would lose the other two.
- **Every other tag survives.** MP3s are edited frame by frame
  (`lib/core/id3.dart`), so comments, lyrics, ReplayGain, iTunes and
  Windows Media frames are copied through byte for byte. The tag library's
  own writer was tested against a real file first and dropped the comment,
  the normalisation data and seven PRIV frames — which is why it is not
  used for MP3.
- **Covers are added, never replaced or dropped.** A track with no cover
  gets the folder's `cover.jpg`/`folder.jpg`, or the Cover Art Archive's
  for the chosen release. A write that would leave a file with fewer
  pictures than it had is refused.
- **Writes are atomic.** The file is copied next to itself, tagged, read
  back with a *different* parser to check the tags and covers landed and
  the audio length is unchanged, and only then renamed over the original.
  A crash at any point leaves the original as it was.
- **Undo is exact.** For MP3 the original tag block is kept and put back
  byte for byte — verified on a phone, the file after undo is identical to
  the file before the save.

Formats: MP3 (frame-level editor), FLAC, M4A, WAV (tag library). Ogg and
Opus are read and played but not written; their cards say so.

## Online, and offline

MusicBrainz (no key needed, data is CC0) is searched by title and artist,
then by title alone — many records are credited to a name the tags do not
use (`シートベルツ` rather than `The Seatbelts`). Candidates are ranked by
how close the recording's length is to the file's, and labelled by release
type: Official Release, Single, Live, Remix, Acoustic, Compilation,
Soundtrack.

Requests are paced at just over one a second, as MusicBrainz asks, with a
User-Agent naming the app. Every successful response is cached on disk,
so a folder looked up once can be worked through again with no signal.
Offline, the card says so, offers a retry, and the filename and folder
suggestions still work.

**Last.fm genres** are optional: add a free API key on the home screen.

**AcoustID** (identifying a track by audio fingerprint) is not included:
it needs Chromaprint's native fingerprinting, which would put a native
build back into an app that currently has none.

## Progress

Progress through each folder is saved as you go, so closing the app half
way through four hundred tracks resumes where you were. The undo history
survives restarts too (the last 2,000 saves).

## Layout

```
lib/core/   pure Dart, no Flutter — all of it tested
  tags.dart        TagSet and Candidate
  id3.dart         frame-preserving ID3v2 editor
  tag_io.dart      atomic read/write/undo on real files
  guess.dart       tags from filenames and folder names
  musicbrainz.dart recording search → candidates
  lastfm.dart      genre suggestions
  net.dart         pacing, caching, one GET
  library.dart     folder scan, queue order, folder covers, batch targets
  store.dart       session progress, undo journal, settings
lib/ui/     the app
  tagger.dart      state: queue, player, lookups, writes, undo
  swipe_screen.dart, home_screen.dart, theme.dart
```

## Android storage

Writing tags into files across shared storage needs **all-files access**
(`MANAGE_EXTERNAL_STORAGE`), granted from Android's own settings screen.
It is asked for when a folder is opened, not at launch.

## Building

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`flutter analyze` and `flutter test` never touch Gradle, so run a release
build after any change to the Android side.

### Signing

`android/app/debug.keystore` is committed on purpose (debug-only, never
used for release signing) so local and CI builds share one identity and
can install over each other. Flutter's default `android/.gitignore` has a
blanket `**/*.keystore`, so the negation below it is what lets the file be
tracked.

```sh
apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
keytool -list -v -keystore android/app/debug.keystore -storepass android -alias androiddebugkey
```

`keytool -printcert -jarfile` only understands legacy v1 JAR signing and
will wrongly call a modern APK unsigned.

## Releasing

Only ever through `scripts/release.sh`: it bumps the version, commits,
pushes, and verifies with `aapt2` that the APK carries the new version
before uploading. Releases are shaped to Obtainium's defaults — bare
version tag, one APK asset, version and build number bumped every time.
The application id is unchanged from the old app, so Obtainium updates it
in place.
