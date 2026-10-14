# MP3 Sorter

Tidies a messy MP3 collection: writes tags, files everything as
`Artist/Title.mp3`, reconciles artist spellings with Levenshtein
matching, finds duplicates, and marks low-bitrate files.

**Nothing is written until you have seen the full list and said yes**, and
every run can be undone. On a collection with no backup that is not a
nicety — a rename rule that is subtly wrong gets applied five thousand
times before anyone notices.

Runs on Android and on Linux desktop from one codebase.

## What it does

| | |
| --- | --- |
| **Scan** | Reads tags and frame headers. Read-only, always. |
| **Quality** | Real bitrate from the MPEG frames, banded and browsable. Computed every scan, never written to the file. |
| **Artists** | Levenshtein clustering finds `ColdPlay` / `Coldplay` and standardises them. |
| **Duplicates** | Three kinds — identical bytes, same audio different tags, same song different encodings. |
| **Plan** | Every proposed change listed and individually rejectable. |
| **Undo** | A journal of what was done, reversed newest-first. |

## Measured on a real collection

5,303 files, 25 GB, scanned in 21 seconds:

```
low quality    1,508      duplicates   698 groups
acceptable     3,223                   750 removable
good             112                   5.33 GB reclaimable
high             454
unreadable         6      plan         5,069 moves
no usable tags   228                   1,597 tag writes
                                       234 left alone
                                       0 validation problems
```

The artist merges it found were all correct, including a genuine typo:
`Haijime Wakai, Kuzumi Totaka` → `Hajime Wakai, Kazumi Totaka`.

## The bitrate is read here, not taken from a tag library

`audio_metadata_reader` reports **64 kbps / 22050 Hz for files that are
really 128 kbps / 44100 Hz** — exactly half of both, the signature of
misreading the two MPEG version bits and then indexing the MPEG2 bitrate
table instead of the MPEG1 one. Checked against `ffprobe`, it was wrong
on six of seven sampled files. A `low quality` flag built on that would
have condemned most of a library.

So `lib/bitrate.dart` reads the frame headers itself. Against ffprobe's
**stream** bitrate it is now **75 of 75 exact**.

Two things that took getting right:

- **Compare against `stream=bit_rate`, not `format=bit_rate`.** The
  format figure is file size ÷ duration, so it includes the ID3 tag and
  embedded album art — on a short track with a big cover that reads 25%
  high, and comparing against it made a correct parser look wrong.
- **Probing at even byte offsets over-samples loud passages**, because
  high-bitrate frames occupy more bytes. The arithmetic mean of such a
  sample reported 243 kbps where the truth was 224. The **harmonic mean**
  of byte-uniform samples recovers the time-weighted average exactly,
  which is what "the bitrate of this file" means.

A Xing/Info/VBRI header is used when present, since it describes the
whole file exactly and no amount of sampling can.

### Quality is computed, not stored

Versions up to 1.0.3 wrote a `low quality` genre into files below 128k.
That was wrong, and 1.0.4 removes it.

Bitrate is derived from the file in about two milliseconds. Writing it
into a tag spent a **real metadata field** — one the owner may have set
themselves — to save a computation that is free, and left 1,500 files
carrying a genre no music player should be showing. Derived data belongs
in the view, not in the thing it was derived from.

So quality is now computed at every scan, shown banded on the home
screen, and **tappable**: each band opens the list of files in it, worst
first, with the bitrate, sample rate, channel count and size that produced
the verdict. The point of knowing a file is poor is to go and re-source
it, and for that you want a list you can read — not a marker buried in
metadata.

The one genre change the app still makes is **taking that marker back**
from files an earlier version wrote it to. It is on by default and only
ever removes.

## Levenshtein, and why normalisation is most of it

Raw edit distance says `The Beatles` and `Beatles` are four apart — on a
seven-character string that is a similarity of 0.64, below any sane
threshold, so the match is missed. Strip the article first and they are
identical. The distance function is the easy half.

The normalisation rules each came from a real pattern: leading and
trailing articles, `&` versus `and`, `(Remastered 2011)` and `[Explicit]`,
`feat. Jay-Z`, leading track numbers, initialisms like `N.W.A.` that must
collapse to `nwa` rather than `n w a`.

Release noise is a **fixed list of known-noise words**, not "strip all
brackets": `(Don't Fear) The Reaper` and `(I Can't Get No) Satisfaction`
are real titles, and discarding their parentheses would merge genuinely
different songs.

All-pairs comparison over a collection is affordable because of
`levenshteinWithin`, which abandons a comparison as soon as it exceeds
the budget — and rejects outright on a length difference, which costs
nothing and eliminates most pairs.

## Three kinds of duplicate

1. **Identical bytes** — a copy, or a Syncthing conflict file.
2. **Same audio, different tags** — one rip tagged twice. The files
   differ in size *because* the tags differ, so a size comparison misses
   it entirely. The commonest kind.
3. **Same song, different encodings** — a 128k and a 320k rip. Only names
   to go on, so a duration check guards it: a three-minute radio edit and
   a six-minute album version share artist and title and are not
   duplicates.

The fingerprint hashes the **audio frames only**, skipping the ID3 tag,
which is what makes case 2 findable. It samples 64 KB from each end plus
the exact audio length rather than hashing 25 GB.

Which copy to keep: best bitrate first (the only difference that cannot
be fixed later), then longest (catching a truncated download), then
tagged over untagged, then the one already filed somewhere sensible.

## Recent folders

Scanned folders are remembered and offered on the home screen, with the
file count last seen and enough of the parent path to tell two folders
called `Music` apart.

**An entry whose folder is not currently mounted stays in the list**,
greyed, rather than being pruned. A collection on a removable card lives
at a path that simply does not exist while the card is out — dropping it
then would empty the list at exactly the moment remembering was useful.
Existence is checked when the row is drawn, never as a reason to forget.

## Saving and reloading a scan

Scanning 3,000 files off an SD card takes **163 seconds on a phone**.
Without a way to save that, every change of mind about a setting costs
another three minutes, so in practice settings do not get changed and the
plan does not get examined properly.

- **Save scan** writes a `.json` beside the collection that loads back
  exactly as scanned.
- **Save report** writes a `.txt` — every proposed move, duplicate group
  and artist merge in full. A 5,000-row list is not reviewable on a
  phone, and pretending otherwise is how a plan gets approved unread.

Both are written next to the music rather than through a save dialog: the
folder is already known to be writable, and a file beside the collection
is easier to find again than one in a picker's idea of "Documents".

A loaded scan describes the collection *as it was*, so it is marked
out-of-date until **Check files** has confirmed the paths are still
there — one stat per file, far cheaper than a rescan.

## Safety

- **Plan, review, apply.** Actions start accepted — the review is for
  spotting what is wrong, and making someone tick 5,000 boxes is how a
  review gets skipped.
- **Nothing is ever unlinked.** Removed duplicates move to a trash folder,
  which makes undoing a deletion the same operation as undoing a move.
- **The journal is written before the next action runs**, so an
  interrupted run leaves an accurate record of how far it got. JSON Lines,
  because a half-written array is unparseable and loses everything.
- **An existing target is refused, never overwritten** — the one mistake
  with no undo.
- **A failure does not abandon the run.** One unwritable file should not
  cost four thousand good changes; the journal records which failed, and
  the screen names them rather than only counting them.
- **Files with no usable artist are left exactly where they are.**
  Filing them as `Unknown Artist/` would overwrite the filename, which is
  the only clue they have left.

## Layout

Everything that decides anything is plain Dart with no Flutter and no
plugin imports, so it tests with no device attached.

| File | Does |
| --- | --- |
| `lib/levenshtein.dart` | Distance, early-abort distance, normalisation, clustering |
| `lib/bitrate.dart` | MPEG frame headers, Xing, quality bands |
| `lib/track.dart` | The model, name inference, filesystem-safe names |
| `lib/duplicates.dart` | Grouping and which copy to keep |
| `lib/plan.dart` | What would change, and validating it |
| `lib/apply.dart` | Doing it, journalling it, undoing it |
| `lib/scanner.dart`, `lib/file_source.dart` | The parts that touch disk |

**132 tests.** `tool/verify_bitrate.dart` and `tool/dry_run.dart` are not
tests — they run against a real collection and need `ffprobe`.

## Planning happens in two passes

Where a file can go depends on which names will still be occupied
afterwards, and that is not known until every track has been considered.
So the planner first works out which files are staying put — already
correctly named, or unfilable — claims those names, and only then assigns
moves.

The single-pass version shipped in 1.0.x and was wrong in a way that only
showed up on a **rescan of an already-sorted folder**. A file already at
its correct name was skipped without reserving that name, so the next file
with identical tags was planned straight onto it:

```
Megitsune.mp3          already correct → skipped, name not claimed
Megitsune (134k).mp3   → planned onto Megitsune.mp3   ← collides
Megitsune (2).mp3      → planned onto Megitsune (134k).mp3  ← collides
```

On a real device that was 120 failures in one run. `validatePlan` now
catches the whole class — a move aimed at a name something else is
keeping — so it would fail the plan rather than the apply.

A second fix came with it: disambiguation can hand a file back **its own**
name, since a file already called `Title (134k).mp3` whose plain target is
taken disambiguates to exactly where it already is. That produced
move-to-self actions, which is why a second run over a tidy folder never
settled. The plan now converges — verified on the real collection, where
a second pass finds zero moves.

## A bug this app shipped with, and how it looked

On a real device the first run worked, and then the screen said **0
applied, 249 failed**, every line reading *"file no longer exists"*.

Nothing was missing. The first run had already moved those files, and the
plan still on screen was built from the scan taken *before* it — so every
path in it pointed at where the file used to be. The app let that stale
plan be applied again, and then reported the consequence in the least
helpful words available.

Three things were wrong, and all three are fixed:

- **The plan survived the run that invalidated it.** A scan is now marked
  out-of-date as soon as anything moves, and the Apply button is disabled
  until it is rechecked or redone.
- **Nothing on screen said so.** There is now a banner on both the home
  and review screens explaining that files have moved and offering the
  one-tap recheck.
- **The error blamed the collection.** It now says the plan is out of
  date rather than that a file has vanished, which is what was actually
  true.

## Two upstream bugs worked around

**The Dart JIT crashes on this workload.** A hot loop over an
externally-backed `Uint8List` — what `RandomAccessFile.readSync` returns —
kills the VM in `FlowGraph::InsertConversion` with *illegal conversion
untagged→tagged*. AOT builds are unaffected, so a release APK would have
shipped fine and **every debug run would have died**. `FileByteSource`
copies each read into a plain list, which costs nothing against the disk
access it follows.

**`permission_handler_android` needs compileSdk 37**, above the 36 that
Flutter 3.47.0 resolves to. Overridden explicitly in
`android/app/build.gradle.kts`; the failure is at `checkDebugAarMetadata`
before any app code compiles.

## Android storage

Bulk renaming across the user's storage needs **all-files access**
(`MANAGE_EXTERNAL_STORAGE`). Scoped storage deliberately cannot do it —
SAF grants per-tree handles, not the arbitrary cross-directory moves that
are this app's entire purpose. Android only grants it from its own
settings screen, and the app degrades to read-only reporting without it.

## Building

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`flutter analyze` and `flutter test` never touch Gradle, so run a release
build after any change to the Android side.

### Linux desktop

The desktop target is scaffolded but needs a toolchain Flutter does not
ship:

```sh
sudo dnf install -y clang cmake ninja-build gtk3-devel
flutter build linux --release
```

That is the build that can reach a collection on a PC. The pure core runs
either way — `tool/dry_run.dart` works today with no toolchain at all.

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

## What it deliberately doesn't do

- **Look anything up online.** No MusicBrainz, no cover art fetching. It
  works from what is already in your files.
- **Guess an artist.** A file called `1739349830600.mp3` is reported, not
  invented into `Unknown Artist/`.
- **Delete anything.** Duplicates go to a trash folder you empty yourself.
- **Write derived data into your files.** Quality is recomputed each scan.
  The only tag writes are artist and title, which are real metadata.
- **Handle FLAC, M4A or OGG.** The frame parser is MP3-specific. The tag
  library covers more, but the quality analysis — the point of the thing —
  does not.
