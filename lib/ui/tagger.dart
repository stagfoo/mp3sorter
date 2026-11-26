/// The state behind the swipe screen: the queue, the card being worked on,
/// its suggestions, the player, and the write/undo plumbing.
///
/// Kept thin on purpose — every decision that can be made without a device
/// (what changed, what a batch touches, how a filename reads) lives in
/// `lib/core` and is tested there. This class sequences those calls.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../core/guess.dart';
import '../core/lastfm.dart';
import '../core/library.dart';
import '../core/musicbrainz.dart';
import '../core/net.dart';
import '../core/store.dart';
import '../core/tag_io.dart';
import '../core/tags.dart';

// Background work goes through these top-level functions rather than
// closures inside [Tagger]'s methods. A closure handed to Isolate.run carries
// its whole enclosing context, and a context that holds `this` drags the
// AudioPlayer along — which cannot cross an isolate boundary, and fails at
// runtime, not at compile time.
Future<int> _cleanTemps(String root) => Isolate.run(() => cleanStaleTemps(root));
Future<TrackInfo> _readTrack(String path) =>
    Isolate.run(() => readTrackInfo(path));
Future<WriteResult> _writeTrack(String path, TagSet tags, CoverImage? cover) =>
    Isolate.run(() => writeTagsAtomic(path, tags, cover: cover));
Future<WriteResult> _undoTrack(
        String path, Uint8List? block, TagSet before, int covers) =>
    Isolate.run(() => undoWrite(path,
        originalTagBlock: block, before: before, coversBefore: covers));

/// Where the cover on a card came from.
enum CoverSource { embedded, folder, coverArtArchive }

/// Everything known about one card.
class CardData {
  CardData(this.path);

  final String path;
  TrackInfo? info;
  List<Candidate> offline = const [];
  List<Candidate> online = const [];
  List<Candidate> genres = const [];
  LookupStatus? lookup;
  bool lookingUp = false;

  /// What will be written if the card is accepted.
  TagSet draft = TagSet.empty;

  /// The chip last tapped, for highlighting.
  Candidate? chosen;

  CoverImage? cover;
  CoverSource? coverSource;
  bool fetchingCover = false;

  bool get loaded => info != null;

  List<Candidate> get candidates => [
        if (info != null && !info!.tags.isEmpty)
          Candidate(
            label: 'As tagged',
            source: CandidateSource.current,
            tags: info!.tags,
          ),
        ...online,
        ...offline,
      ];

  /// The file will gain a cover it does not have.
  bool get addsCover =>
      cover != null && coverSource != CoverSource.embedded;
}

class Tagger extends ChangeNotifier {
  Tagger({
    required this.appDir,
    required this.settings,
    required this.journal,
    required this.root,
    required this.session,
    required this.queue,
    Fetcher? fetcher,
  }) : _fetch = fetcher ?? httpFetcher() {
    final cache = LookupCache(File('${appDir.path}/lookup_cache.json'));
    _mb = MusicBrainzLookup(JsonClient(fetch: _fetch, cache: cache));
    _lastFm = JsonClient(
      fetch: _fetch,
      cache: cache,
      pacer: Pacer(interval: const Duration(milliseconds: 250)),
    );
    _cache = cache;
  }

  final Directory appDir;
  final Settings settings;
  final Journal journal;
  final String root;
  final Session session;

  /// Every audio file under [root], in order. Never shrinks during a session;
  /// done tracks are skipped over by [index] instead.
  final List<String> queue;

  final Fetcher _fetch;
  late final MusicBrainzLookup _mb;
  late final JsonClient _lastFm;
  late final LookupCache _cache;
  final Pacer _coverPacer = Pacer(interval: const Duration(milliseconds: 500));

  final AudioPlayer player = AudioPlayer();
  final Map<String, CardData> _cards = {};

  int index = 0;
  bool busy = false;
  String? message;
  bool offline = false;

  /// Increments whenever the visible card changes, so the screen can reset
  /// its drag state and the editor fields.
  int cardEpoch = 0;

  static Future<Tagger> open({
    required Directory appDir,
    required Settings settings,
    required Journal journal,
    required String root,
  }) async {
    // A write killed mid-way leaves only a stale hidden copy (the original
    // is never touched until the final rename); tidy those away.
    await _cleanTemps(root);
    final session = await Session.load(appDir, root);
    final queue = await scanFolder(root, recursive: settings.includeSubfolders);
    final t = Tagger(
      appDir: appDir,
      settings: settings,
      journal: journal,
      root: root,
      session: session,
      queue: queue,
    );
    t.index = t._nextPending(0) ?? queue.length;
    return t;
  }

  // ---- queue -------------------------------------------------------------

  bool get finished => index >= queue.length;
  String? get currentPath => finished ? null : queue[index];
  CardData? get current => currentPath == null ? null : card(currentPath!);

  int get doneCount =>
      queue.where((p) => session.of(p) == TrackStatus.accepted).length;
  int get skippedCount =>
      queue.where((p) => session.of(p) == TrackStatus.skipped).length;
  int get pendingCount => queue.where(session.isPending).length;

  CardData card(String path) => _cards.putIfAbsent(path, () => CardData(path));

  int? _nextPending(int from) {
    for (var i = from; i < queue.length; i++) {
      if (session.isPending(queue[i])) return i;
    }
    return null;
  }

  int? _prevPending(int before) {
    for (var i = before - 1; i >= 0; i--) {
      if (session.isPending(queue[i])) return i;
    }
    return null;
  }

  /// The pending tracks either side of the current one, for the peeking
  /// cards in the carousel.
  String? get previousPath {
    final i = _prevPending(index);
    return i == null ? null : queue[i];
  }

  String? get nextPath {
    final i = _nextPending(index + 1);
    return i == null ? null : queue[i];
  }

  /// Tracks a swipe-up would apply the album to.
  List<int> get batchIndexes => batchTargets(queue, index, session.isPending);

  // ---- loading a card ----------------------------------------------------

  Future<void> start() async {
    await _show();
  }

  Future<void> _show() async {
    cardEpoch++;
    message = null;
    notifyListeners();
    final path = currentPath;
    if (path == null) {
      await player.stop();
      return;
    }
    unawaited(_play(path));
    await _load(path, primary: true);
    // Warm up the next two cards — reading tags and a cached lookup are
    // cheap, and the swipe after this one then shows a full card at once.
    var i = index;
    for (var n = 0; n < 2; n++) {
      final next = _nextPending(i + 1);
      if (next == null) break;
      i = next;
      unawaited(_load(queue[next], primary: false));
    }
  }

  Future<void> _play(String path) async {
    try {
      await player.setFilePath(path);
      await player.setVolume(settings.volume);
      await player.play();
    } catch (_) {
      // An undecodable file still deserves a card — the tags may be what
      // needs fixing — so a playback failure is not fatal.
    }
  }

  Future<void> _load(String path, {required bool primary}) async {
    final c = card(path);
    if (!c.loaded) {
      c.info = await _readTrack(path);
      c.offline = offlineCandidates(filePath: path, root: root);
      // Start from what the file says; where it says nothing, from the best
      // offline guess. Online suggestions are offered, never auto-applied.
      var draft = c.info!.tags;
      for (final o in c.offline.reversed) {
        draft = o.tags.overlaidWith(draft);
      }
      c.draft = draft;
      if (c.info!.cover != null) {
        c.cover = c.info!.cover;
        c.coverSource = CoverSource.embedded;
      } else {
        final fc = await folderCover(dirOf(path));
        if (fc != null) {
          c.cover = fc;
          c.coverSource = CoverSource.folder;
        }
      }
      if (_isCurrent(path)) notifyListeners();
    }
    if (c.lookup == null && !c.lookingUp) {
      await _lookup(c);
    }
  }

  bool _isCurrent(String path) => currentPath == path;

  Future<void> _lookup(CardData c) async {
    final fromName = c.offline.isEmpty ? TagSet.empty : c.offline.first.tags;
    final terms = searchTerms(c.info?.tags ?? TagSet.empty, fromName);
    if (terms == null) {
      c.lookup = LookupStatus.noMatch;
      return;
    }
    c.lookingUp = true;
    if (_isCurrent(c.path)) notifyListeners();
    final (status, found) = await _mb.candidates(
      title: terms.title,
      artist: terms.artist,
      fileSeconds: c.info?.durationSeconds,
    );
    c.online = found;
    c.lookup = status;
    offline = status == LookupStatus.offline;

    final artist = terms.artist;
    if (settings.lastFmKey.isNotEmpty && artist != null) {
      c.genres = await LastFmLookup(_lastFm, settings.lastFmKey)
          .genres(artist: artist, title: terms.title);
    }
    c.lookingUp = false;
    unawaited(_cache.save());

    // No cover anywhere yet: fetch the best match's, so it can be embedded.
    if (c.cover == null && found.isNotEmpty) {
      await _fetchCover(c, found.firstWhere(
        (x) => x.releaseId != null,
        orElse: () => found.first,
      ));
    }
    if (_isCurrent(c.path)) notifyListeners();
  }

  Future<void> _fetchCover(CardData c, Candidate cand) async {
    if (cand.releaseId == null && cand.releaseGroupId == null) return;
    c.fetchingCover = true;
    if (_isCurrent(c.path)) notifyListeners();
    final cacheDir = Directory('${appDir.path}/covers');
    final key = cand.releaseId ?? cand.releaseGroupId!;
    final cached = File('${cacheDir.path}/$key.img');
    Uint8List? bytes;
    try {
      if (await cached.exists()) {
        bytes = await cached.readAsBytes();
      } else {
        for (final url in [
          if (cand.releaseId != null) releaseCoverUrl(cand.releaseId!),
          if (cand.releaseGroupId != null)
            releaseGroupCoverUrl(cand.releaseGroupId!),
        ]) {
          await _coverPacer.wait();
          final r = await _fetch(url);
          if (r.ok && sniffImageType(r.bytes) != null) {
            bytes = r.bytes;
            await cacheDir.create(recursive: true);
            await cached.writeAsBytes(bytes);
            break;
          }
        }
      }
    } catch (_) {
      // Offline or the archive is slow: the card simply has no cover yet.
    }
    final type = bytes == null ? null : sniffImageType(bytes);
    if (bytes != null && type != null && c.coverSource != CoverSource.embedded) {
      c.cover = CoverImage(bytes, type);
      c.coverSource = CoverSource.coverArtArchive;
    }
    c.fetchingCover = false;
    if (_isCurrent(c.path)) notifyListeners();
  }

  /// Retries a lookup that failed because the network was down.
  Future<void> retryLookup() async {
    final c = current;
    if (c == null) return;
    c.lookup = null;
    await _lookup(c);
  }

  // ---- editing -----------------------------------------------------------

  void choose(Candidate cand) {
    final c = current;
    if (c == null) return;
    c.chosen = cand;
    c.draft = c.draft.overlaidWith(cand.tags);
    cardEpoch++; // the editor fields re-read the draft
    notifyListeners();
    if (c.coverSource != CoverSource.embedded &&
        cand.source == CandidateSource.musicBrainz) {
      // A different release may have a different cover; follow the choice.
      unawaited(_fetchCover(c, cand));
    }
  }

  void edit(TagSet Function(TagSet) change) {
    final c = current;
    if (c == null) return;
    c.draft = change(c.draft);
    // No notify: the text field already shows what was typed, and a rebuild
    // per keystroke would fight the cursor.
  }

  // ---- playback ----------------------------------------------------------

  Future<void> togglePlay() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    notifyListeners();
  }

  Future<void> setVolume(double v) async {
    settings.volume = v;
    await player.setVolume(v);
    unawaited(settings.save());
    notifyListeners();
  }

  // ---- the three swipes --------------------------------------------------

  /// Swipe right: write the draft (and the cover, if the file had none).
  Future<void> accept() async {
    final c = current;
    if (c == null || busy) return;
    busy = true;
    notifyListeners();
    final ok = await _write(c.path, c.draft, c.addsCover ? c.cover : null,
        group: journal.newId());
    busy = false;
    if (ok) await _advance();
    notifyListeners();
  }

  /// Swipe left: leave the file alone and move on.
  Future<void> skip() async {
    final path = currentPath;
    if (path == null || busy) return;
    session.set(path, TrackStatus.skipped);
    unawaited(session.save());
    await _advance();
  }

  /// Swipe up: accept this card, then write its album, album artist, year,
  /// genre and cover to every waiting track left in the same folder.
  Future<int> batch() async {
    final c = current;
    if (c == null || busy) return 0;
    final targets = batchIndexes;
    busy = true;
    notifyListeners();
    final group = journal.newId();
    final shared = c.draft.albumFields();
    var written = 0;
    var failed = 0;
    if (await _write(c.path, c.draft, c.addsCover ? c.cover : null,
        group: group)) {
      for (final i in targets) {
        final path = queue[i];
        final other = card(path);
        // Each track keeps its own title, artist and number — read from its
        // own tags or its own filename — with the album fields on top.
        if (!other.loaded) {
          other.info = await _readTrack(path);
          other.offline = offlineCandidates(filePath: path, root: root);
        }
        var own = other.info!.tags;
        for (final o in other.offline.reversed) {
          own = o.tags.overlaidWith(own);
        }
        final ok = await _write(path, own.overlaidWith(shared),
            other.info!.hasCover ? null : c.cover,
            group: group, quiet: true);
        ok ? written++ : failed++;
      }
    }
    busy = false;
    message = failed == 0
        ? 'Album applied to ${written + 1} tracks'
        : 'Album applied to ${written + 1} tracks — $failed could not be written';
    await _advance();
    return written;
  }

  Future<bool> _write(String path, TagSet tags, CoverImage? cover,
      {required String group, bool quiet = false}) async {
    final result = await _writeTrack(path, tags, cover);
    if (!result.ok) {
      session.set(path, TrackStatus.failed);
      unawaited(session.save());
      if (!quiet) message = "Couldn't save: ${result.error}";
      return false;
    }
    await journal.record(
      group: group,
      path: path,
      before: result.before!,
      coversBefore: result.coversBefore,
      originalTagBlock: result.originalTagBlock,
      noop: result.unchanged,
    );
    session.set(path, TrackStatus.accepted);
    unawaited(session.save());
    // The card's view of the file is now stale.
    _cards.remove(path);
    return true;
  }

  Future<void> _advance() async {
    index = _nextPending(index + 1) ?? _nextPending(0) ?? queue.length;
    await _show();
  }

  // ---- undo --------------------------------------------------------------

  bool get canUndo => journal.entries.isNotEmpty;

  /// Undoes the last save (or the whole last batch), and brings its first
  /// track back as the current card.
  Future<void> undo() async {
    final group = journal.lastGroup();
    if (group.isEmpty || busy) return;
    busy = true;
    notifyListeners();
    var failed = 0;
    String? first;
    for (final e in group) {
      final block = await journal.blockOf(e);
      final path = e.path;
      final before = e.before;
      final covers = e.coversBefore;
      // A track accepted as it was had nothing written; undoing it only puts
      // it back in the queue.
      final r = e.noop
          ? WriteResult.ok(before: before, coversBefore: covers)
          : await _undoTrack(path, block, before, covers);
      if (r.ok) {
        await journal.remove(e);
        session.set(path, TrackStatus.pending);
        _cards.remove(path);
        first = path;
      } else {
        failed++;
      }
    }
    await session.save();
    busy = false;
    message = failed == 0
        ? 'Undone'
        : '$failed could not be undone — the file changed since?';
    final i = first == null ? -1 : queue.indexOf(first);
    if (i >= 0) index = i;
    await _show();
  }

  /// Brings back the last skipped track before the current one.
  Future<void> back() async {
    for (var i = index - 1; i >= 0; i--) {
      if (session.of(queue[i]) == TrackStatus.skipped) {
        session.set(queue[i], TrackStatus.pending);
        unawaited(session.save());
        index = i;
        await _show();
        return;
      }
    }
  }

  @override
  void dispose() {
    player.dispose();
    unawaited(_cache.save());
    super.dispose();
  }
}
