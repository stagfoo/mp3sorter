/// The network, kept small: one GET function, a rate limiter, and a cache
/// that makes the app usable offline.
///
/// Carried over from the previous version of the app, where the pacing rules
/// were learned the hard way against MusicBrainz's real rate limiting.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'version.dart';

/// Identifies this app to MusicBrainz, as their guidelines require.
const String kUserAgent =
    'mp3sorter/$kAppVersion ( https://github.com/stagfoo/mp3sorter )';

/// One request per second to MusicBrainz, with a little margin: the limit is
/// enforced on arrival time, and aiming exactly at it crosses it whenever the
/// network bunches two requests together.
const Duration kMusicBrainzInterval = Duration(milliseconds: 1100);

/// Refuses to let calls happen faster than an interval.
class Pacer {
  Pacer({
    this.interval = kMusicBrainzInterval,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  })  : _now = clock ?? DateTime.now,
        _sleep = sleep ?? Future.delayed;

  final Duration interval;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  DateTime? _last;
  Future<void> _queue = Future.value();

  Duration debt() {
    final last = _last;
    if (last == null) return Duration.zero;
    final since = _now().difference(last);
    return since >= interval ? Duration.zero : interval - since;
  }

  /// Waits for this caller's turn. Callers are served in order, so two cards
  /// looking up at once cannot both decide the slot is free.
  Future<void> wait() {
    final turn = _queue.then((_) async {
      final owed = debt();
      if (owed > Duration.zero) await _sleep(owed);
      _last = _now();
    });
    _queue = turn;
    return turn;
  }
}

/// What one HTTP GET came back with.
class FetchResult {
  const FetchResult(this.status, this.bytes, {this.contentType});

  final int status;
  final Uint8List bytes;
  final String? contentType;

  bool get ok => status >= 200 && status < 300;
  bool get notFound => status == 404;

  /// Worth trying again later. 503 is MusicBrainz's rate-limit answer.
  bool get transient => status == 429 || status >= 500;

  String get text => utf8.decode(bytes, allowMalformed: true);
}

typedef Fetcher = Future<FetchResult> Function(Uri url);

/// The real network. `dart:io` rather than a package — one GET with a
/// User-Agent and redirects followed (the Cover Art Archive answers with a
/// 307 to archive.org) does not need one.
Fetcher httpFetcher({Duration timeout = const Duration(seconds: 15)}) {
  final client = HttpClient()
    ..userAgent = kUserAgent
    ..connectionTimeout = timeout;

  return (Uri url) async {
    final request = await client.getUrl(url).timeout(timeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json, image/*');
    final response = await request.close().timeout(timeout);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
    }
    return FetchResult(
      response.statusCode,
      builder.takeBytes(),
      contentType: response.headers.contentType?.mimeType,
    );
  };
}

/// Recognises JPEG and PNG by their first bytes.
///
/// The declared mimetype goes into the tag, and a JPEG announced as a PNG
/// shows as a broken image in players that believe the declaration.
String? sniffImageType(Uint8List bytes) {
  if (bytes.length < 12) return null;
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  return null;
}

/// Remembers successful responses on disk, so a folder looked up once can be
/// worked through again on a train with no signal.
///
/// Only successes are cached. A failure is a reason to try again later, and
/// caching it would make one bad minute permanent.
class LookupCache {
  LookupCache(this.file, {this.maxEntries = 4000});

  final File? file;
  final int maxEntries;
  final Map<String, String> _entries = {};
  bool _loaded = false;
  bool _dirty = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = file;
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) {
        raw.forEach((k, v) {
          if (k is String && v is String) _entries[k] = v;
        });
      }
    } catch (_) {
      // A corrupt cache is just an empty one.
    }
  }

  String? get(String key) => _entries[key];

  void put(String key, String body) {
    _entries.remove(key);
    _entries[key] = body;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _dirty = true;
  }

  int get length => _entries.length;

  /// Written through a temporary file and a rename, so a crash mid-save
  /// leaves the previous cache rather than half of one.
  Future<void> save() async {
    final f = file;
    if (f == null || !_dirty) return;
    _dirty = false;
    final tmp = File('${f.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode(_entries), flush: true);
    await tmp.rename(f.path);
  }
}

/// Why a lookup came back empty. Offline and rate-limited are temporary and
/// are shown as such on the card; "nothing found" is an answer.
enum LookupStatus { ok, cached, noMatch, offline, rateLimited }

/// A cached, paced GET for JSON APIs.
class JsonClient {
  JsonClient({required this.fetch, required this.cache, Pacer? pacer})
      : pacer = pacer ?? Pacer();

  final Fetcher fetch;
  final LookupCache cache;
  final Pacer pacer;

  Future<(LookupStatus, String?)> get(Uri url) async {
    await cache.load();
    final key = url.toString();
    final hit = cache.get(key);
    if (hit != null) return (LookupStatus.cached, hit);

    // One retry after a rate limit, with a real pause. More than that and
    // the user is staring at a spinner for something they can type.
    for (var attempt = 0; attempt < 2; attempt++) {
      final FetchResult r;
      try {
        await pacer.wait();
        r = await fetch(url);
      } catch (_) {
        return (LookupStatus.offline, null);
      }
      if (r.ok) {
        final body = r.text;
        cache.put(key, body);
        return (LookupStatus.ok, body);
      }
      if (r.transient) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        return (LookupStatus.rateLimited, null);
      }
      return (LookupStatus.noMatch, null);
    }
    return (LookupStatus.rateLimited, null);
  }
}
