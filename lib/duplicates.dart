/// Finding the same song twice.
///
/// Three kinds of duplicate turn up in a real collection, and they want
/// different treatment:
///
///  1. **The same bytes** — the file copied twice, or a Syncthing
///     conflict copy. Safe to delete one without thinking.
///  2. **The same audio, different tags** — one rip, tagged twice. The
///     file sizes differ because the tags differ, so a size comparison
///     misses it entirely. This is the commonest kind.
///  3. **The same song, different encodings** — a 128k rip and a 320k
///     rip. Not byte-identical anywhere, only recognisable from artist
///     and title, and the one case where which copy you keep matters.
///
/// Nothing here deletes anything. It returns groups and a recommendation,
/// and the decision stays with the person looking at the screen.
library;

import 'levenshtein.dart';
import 'track.dart';

/// Why a group was put together. Ordered by how certain it is, so the
/// UI can show the safe ones first and the judgement calls last.
enum DuplicateKind {
  /// Byte-for-byte identical.
  identicalFile,

  /// Same audio stream, different metadata.
  sameAudio,

  /// Same artist and title, different encodings.
  sameSong,
}

/// A set of files that are the same thing.
class DuplicateGroup {
  const DuplicateGroup({
    required this.kind,
    required this.tracks,
    required this.keep,
  });

  final DuplicateKind kind;

  /// Every file in the group, including [keep].
  final List<Track> tracks;

  /// The copy worth keeping. A recommendation, not a decision.
  final Track keep;

  /// The copies the recommendation would remove.
  List<Track> get discard =>
      [for (final t in tracks) if (t.path != keep.path) t];

  /// Bytes freed by taking the recommendation.
  int get reclaimableBytes =>
      discard.fold(0, (sum, t) => sum + t.sizeBytes);
}

/// Picks the copy to keep from a set that are the same song.
///
/// Quality first, because that is the only difference that cannot be
/// fixed later — tags and filenames can be rewritten, a 128k encode
/// cannot be un-lossy-compressed. Then the longer file, which catches a
/// truncated download sitting next to a complete one. Then the one
/// already in a sensible place, on the reasoning that a file inside
/// `Artist/` was deliberately filed and a loose one was not. Path last,
/// so the answer never depends on directory walk order.
Track pickKeeper(List<Track> candidates) {
  final sorted = [...candidates]..sort((a, b) {
      final byQuality = (b.bitrateKbps ?? 0).compareTo(a.bitrateKbps ?? 0);
      if (byQuality != 0) return byQuality;

      final byDuration = (b.duration?.inMilliseconds ?? 0)
          .compareTo(a.duration?.inMilliseconds ?? 0);
      if (byDuration != 0) return byDuration;

      // A tagged file is better than an untagged one carrying the same
      // audio: it is the copy that keeps working in a music player.
      final byTags = (b.hasUsableTags ? 1 : 0) - (a.hasUsableTags ? 1 : 0);
      if (byTags != 0) return byTags;

      // Shallower paths are the deliberately filed ones.
      final byDepth =
          '/'.allMatches(a.path).length - '/'.allMatches(b.path).length;
      if (byDepth != 0) return byDepth;

      return a.path.compareTo(b.path);
    });
  return sorted.first;
}

/// Groups tracks that are the same file, the same audio, or the same song.
///
/// A track belongs to at most one group, and the most certain kind wins:
/// two byte-identical files are reported as identical rather than also
/// appearing in a looser "same song" group, which would make the counts
/// on screen add up to more than the collection.
List<DuplicateGroup> findDuplicates(
  List<Track> tracks, {
  bool includeSameSong = true,
  double nameThreshold = kSameNameThreshold,
}) {
  final groups = <DuplicateGroup>[];
  final claimed = <String>{};

  DuplicateGroup? build(DuplicateKind kind, List<Track> members) {
    final fresh = [for (final t in members) if (!claimed.contains(t.path)) t];
    if (fresh.length < 2) return null;
    for (final t in fresh) {
      claimed.add(t.path);
    }
    return DuplicateGroup(
      kind: kind,
      tracks: fresh,
      keep: pickKeeper(fresh),
    );
  }

  // 1. Identical bytes: same size and same audio fingerprint. Size alone
  //    is not enough — two different 4,194,304-byte files are common
  //    enough to matter.
  final byExact = <String, List<Track>>{};
  for (final t in tracks) {
    if (!t.isReadable || t.audioFingerprint == null) continue;
    byExact
        .putIfAbsent('${t.sizeBytes}:${t.audioFingerprint}', () => [])
        .add(t);
  }
  for (final members in byExact.values) {
    final g = build(DuplicateKind.identicalFile, members);
    if (g != null) groups.add(g);
  }

  // 2. Same audio, different tags. The fingerprint covers the audio
  //    frames only, so a retagged copy matches here while differing in
  //    size — the kind a naive deduplicator never finds.
  final byAudio = <String, List<Track>>{};
  for (final t in tracks) {
    if (!t.isReadable || t.audioFingerprint == null) continue;
    byAudio.putIfAbsent(t.audioFingerprint!, () => []).add(t);
  }
  for (final members in byAudio.values) {
    final g = build(DuplicateKind.sameAudio, members);
    if (g != null) groups.add(g);
  }

  if (!includeSameSong) return groups;

  // 3. Same song, different encodings. Only names to go on, so this is
  //    the one that can be wrong — a live version and a studio version
  //    share artist and title and are not duplicates. Hence a duration
  //    sanity check, and hence nothing acting on it unreviewed.
  final remaining = [
    for (final t in tracks)
      if (t.isReadable && !claimed.contains(t.path)) t,
  ];

  // Bucketed by normalised artist before comparing titles. Comparing
  // every title against every other is 14 million pairs on this
  // collection; within one artist it is a few hundred.
  final byArtist = <String, List<Track>>{};
  for (final t in remaining) {
    final names = inferNames(t);
    final artist = names.artist;
    if (artist == null || names.title == null) continue;
    byArtist.putIfAbsent(normaliseForMatching(artist), () => []).add(t);
  }

  for (final entry in byArtist.entries) {
    final candidates = entry.value;
    if (candidates.length < 2) continue;

    final used = <String>{};
    for (var i = 0; i < candidates.length; i++) {
      final a = candidates[i];
      if (used.contains(a.path)) continue;
      final members = <Track>[a];
      for (var j = i + 1; j < candidates.length; j++) {
        final b = candidates[j];
        if (used.contains(b.path)) continue;
        final ta = inferNames(a).title!;
        final tb = inferNames(b).title!;
        if (nameSimilarity(ta, tb) < nameThreshold) continue;
        if (!_durationsAgree(a, b)) continue;
        members.add(b);
      }
      if (members.length > 1) {
        final g = build(DuplicateKind.sameSong, members);
        if (g != null) {
          groups.add(g);
          for (final m in members) {
            used.add(m.path);
          }
        }
      }
    }
  }

  // Most certain first, then biggest saving, then path so two runs over
  // the same collection produce the same report.
  groups.sort((a, b) {
    final byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    final bySaving = b.reclaimableBytes.compareTo(a.reclaimableBytes);
    if (bySaving != 0) return bySaving;
    return a.keep.path.compareTo(b.keep.path);
  });
  return groups;
}

/// How far two running times may differ and still be the same recording.
///
/// Five percent absorbs a different amount of silence at the end and the
/// encoder delay, while still separating a three-minute radio edit from a
/// six-minute album version — which are genuinely different files that
/// share an artist and a title.
const double kDurationTolerance = 0.05;

bool _durationsAgree(Track a, Track b) {
  final da = a.duration?.inMilliseconds;
  final db = b.duration?.inMilliseconds;
  // Unknown durations are not evidence either way, so they do not veto a
  // match that the names already support.
  if (da == null || db == null || da == 0 || db == 0) return true;
  final diff = (da - db).abs();
  return diff <= (da > db ? da : db) * kDurationTolerance;
}

/// A summary for the screen before anyone opens a group.
class DuplicateSummary {
  const DuplicateSummary({
    required this.groups,
    required this.filesInvolved,
    required this.removable,
    required this.reclaimableBytes,
  });

  final int groups;
  final int filesInvolved;
  final int removable;
  final int reclaimableBytes;

  bool get isEmpty => groups == 0;
}

DuplicateSummary summariseDuplicates(List<DuplicateGroup> groups) {
  var files = 0, removable = 0, bytes = 0;
  for (final g in groups) {
    files += g.tracks.length;
    removable += g.discard.length;
    bytes += g.reclaimableBytes;
  }
  return DuplicateSummary(
    groups: groups.length,
    filesInvolved: files,
    removable: removable,
    reclaimableBytes: bytes,
  );
}
