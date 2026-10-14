/// The files in one quality band.
///
/// What replaced writing `low quality` into the genre field. The point of
/// knowing a file is poor is to go and re-source it, and for that you
/// need a list you can read and act on — not a marker buried in metadata
/// that a player will happily show as the track's genre.
///
/// Nothing here writes anything.
library;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'bitrate.dart';
import 'track.dart';

class QualityBrowseScreen extends StatelessWidget {
  const QualityBrowseScreen({
    super.key,
    required this.app,
    required this.band,
  });

  final AppState app;
  final QualityBand band;

  @override
  Widget build(BuildContext context) {
    final tracks = app.tracksInBand(band);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('${band.name} · ${tracks.length} files')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              switch (band) {
                QualityBand.low =>
                  'Below ${kLowQualityKbps}k, or at a sample rate that '
                      'threw away the top octave before encoding. Worst '
                      'first — these are the ones worth re-sourcing.',
                QualityBand.acceptable =>
                  'Fine for casual listening, visibly short of the source.',
                QualityBand.good => 'What most people would call good.',
                QualityBand.high => 'Transparent, or near enough.',
              },
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: tracks.length,
              itemExtent: 68,
              itemBuilder: (context, i) => _Row(track: tracks[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = inferNames(track);
    return ListTile(
      dense: true,
      title: Text(
        names.isComplete
            ? '${names.artist} — ${names.title}'
            : track.path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        // The numbers that decide the band, so the verdict is checkable
        // rather than something to take on trust.
        '${track.bitrateKbps ?? "?"}k'
        '${track.isVbr ? " VBR" : ""}'
        ' · ${(track.sampleRate ?? 0) ~/ 1000}kHz'
        '${track.isMono ? " · mono" : ""}'
        ' · ${(track.sizeBytes / 1048576).toStringAsFixed(1)} MB',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
