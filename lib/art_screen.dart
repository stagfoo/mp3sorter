/// Collecting album art.
///
/// Arranged around the one decision that matters here: **nothing reaches
/// the network until it is asked to.** The screen opens on the offline
/// pass — covers already on a sibling track, or already sitting in the
/// album's folder — says how much that fixes, and only then offers to go
/// and ask about the rest. Scanning and sorting stay entirely offline,
/// as they always were.
library;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'artwork.dart';
import 'cover_art.dart';
import 'plan.dart';

class ArtScreen extends StatefulWidget {
  const ArtScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ArtScreen> createState() => _ArtScreenState();
}

class _ArtScreenState extends State<ArtScreen> {
  bool _cancelled = false;

  AppState get app => widget.app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final summary = app.artSummary;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Album art'),
            actions: [
              if (app.artBusy)
                IconButton(
                  tooltip: 'Stop',
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () => setState(() => _cancelled = true),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (app.artBusy) _progress(theme),
              if (!app.artBusy && app.lastArtResult != null) _result(theme),
              if (!app.artBusy && (summary == null || app.artIsStale))
                _intro(theme),
              if (!app.artBusy && summary != null && !app.artIsStale) ...[
                _summaryCard(theme, summary),
                const SizedBox(height: 12),
                if (summary.needLookup > 0 && !app.artLookupRan)
                  _onlineOffer(theme, summary),
                if (app.artNotes.isNotEmpty) _notes(theme),
                if (app.artPlan.isNotEmpty) _planCard(theme),
                const SizedBox(height: 12),
                ..._albumRows(theme),
              ],
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------

  Widget _intro(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                app.artIsStale ? 'Check again' : 'Find missing covers',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                app.artIsStale
                    ? 'Covers were just written, so the counts above are '
                        'about how things were before that. Check again to '
                        'see what is left.'
                    : 'First pass is entirely offline: where one track on '
                        'an album already has a cover, the rest of the '
                        'album can have it too, and an image already '
                        'sitting in the folder can be used the same '
                        'way.\n\n'
                        'This reads every embedded cover to find out which '
                        'files have one, so it is slower than the file '
                        'scan. Nothing is written until you say so.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: app.scan == null ? null : () => app.scanArt(),
                icon: const Icon(Icons.image_search),
                label: Text('Check ${app.scan?.tracks.length ?? 0} files'),
              ),
            ],
          ),
        ),
      );

  Widget _progress(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(app.progressLabel, style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: app.progressTotal == 0
                    ? null
                    : app.progressDone / app.progressTotal,
              ),
              const SizedBox(height: 8),
              Text('${app.progressDone} of ${app.progressTotal}',
                  style: theme.textTheme.bodySmall),
              if (_cancelled)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('stopping after this one…',
                      style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      );

  Widget _summaryCard(ThemeData theme, ArtSummary s) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.allDone
                    ? 'Every album has a cover'
                    : '${s.filesMissing} files with no cover',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              _line(theme, '${s.albums}', 'albums found'),
              _line(theme, '${s.complete}', 'already complete'),
              _line(theme, '${s.fromSibling}',
                  'can be filled from another track on the album'),
              _line(theme, '${s.fromFolder}',
                  'can be filled from an image in the folder'),
              _line(theme, '${s.needLookup}', 'have no cover anywhere'),
              if (s.anythingOffline) ...[
                const SizedBox(height: 10),
                Text(
                  '${s.filesFixableOffline} files can be fixed right now '
                  'without a network.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if ((app.artScan?.unreadable.length ?? 0) > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${app.artScan!.unreadable.length} files could not be '
                  'read — they are listed in the bug report.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      );

  /// The prompt, which is the whole point of the arrangement.
  Widget _onlineOffer(ThemeData theme, ArtSummary s) => Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.cloud_outlined, size: 18,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Look the rest up online?',
                        style: theme.textTheme.titleSmall),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${s.needLookup} albums have no cover on any of their '
                'files and none in their folder. Those can be looked up '
                'at MusicBrainz and the Cover Art Archive — open data, no '
                'account needed.\n\n'
                'One request a second, which is their limit, so this '
                'takes about ${_minutesFor(s.needLookup)}. Only the '
                'artist and album names are sent. Nothing is written '
                'until you approve it, like everything else here.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Spotify was the obvious thing to try and cannot be used: '
                'their terms forbid storing or caching their cover art, '
                'which is exactly what embedding it in your files is.',
                style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  setState(() => _cancelled = false);
                  final message = await app.fetchMissingArt(
                      isCancelled: () => _cancelled);
                  if (mounted) _say(message);
                },
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text('Look up ${s.needLookup} albums'),
              ),
            ],
          ),
        ),
      );

  Widget _notes(ThemeData theme) => Card(
        child: ExpansionTile(
          title: Text('${app.artNotes.length} albums still without a cover',
              style: theme.textTheme.titleSmall),
          subtitle: Text('why, for each one', style: theme.textTheme.bodySmall),
          children: [
            for (final note in app.artNotes)
              ListTile(
                dense: true,
                title: Text(note, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      );

  Widget _planCard(ThemeData theme) {
    final covers =
        app.artPlan.where((a) => a.kind == ActionKind.writeCover).length;
    final embeds =
        app.artPlan.where((a) => a.kind == ActionKind.embedArt).length;
    final approved = app.approvedArt.actionCount;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ready to write', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            _line(theme, '$covers', 'cover files beside their albums'),
            _line(theme, '$embeds', 'covers embedded into files'),
            const SizedBox(height: 10),
            Text(
              'Both, because a cover file is what a file browser and most '
              'desktop players look for, and an embedded one is what '
              'travels with the file to a phone or a car.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: approved == 0 ? null : () => app.applyArt(),
              icon: const Icon(Icons.save_outlined),
              label: Text('Write $approved changes'),
            ),
            const SizedBox(height: 4),
            Text('Undoable from the main screen, like every other change.',
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  /// Every album, so a wrong match is visible before it is written into
  /// forty files. The lookup ones first — those are the ones worth
  /// checking.
  List<Widget> _albumRows(ThemeData theme) {
    final interesting = [
      for (final a in app.albums)
        if (!a.isSatisfied) a,
    ];
    if (interesting.isEmpty) return const [];

    return [
      Text('Albums', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      for (final album in interesting)
        ListTile(
          dense: true,
          leading: Icon(
            switch (album.source) {
              ArtSource.sibling => Icons.audiotrack,
              ArtSource.folderImage => Icons.folder_outlined,
              ArtSource.downloaded => Icons.cloud_done_outlined,
              ArtSource.needsLookup => Icons.help_outline,
              ArtSource.alreadyPresent => Icons.check,
            },
            size: 18,
            color: album.needsNetwork
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.primary,
          ),
          title: Text('${album.artist} — ${album.album}',
              style: theme.textTheme.bodyMedium),
          subtitle: Text(
            album.needsNetwork
                ? 'no cover found'
                : '${album.tracksMissingArt.length} files, '
                    '${_sourceLabel(album.source)}',
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }

  Widget _result(ThemeData theme) {
    final r = app.lastArtResult!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.succeeded} written, ${r.failed} failed',
                style: theme.textTheme.titleMedium),
            if (r.errors.isNotEmpty) ...[
              const SizedBox(height: 8),
              // Every one of them. A run that says "12 failed" without
              // saying which is a run nobody can act on.
              for (final e in r.errors)
                Text(e,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(ThemeData theme, String n, String what) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(n,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(what, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );

  void _say(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// Rounded up and in whole minutes, because the honest number is
  /// "however long MusicBrainz takes" and a precise-looking estimate
  /// that is wrong is worse than a vague one that is right.
  String _minutesFor(int albums) {
    // Up to three requests per album: the search, a title-only retry
    // when that finds nothing, and the image.
    final seconds = albums * kMusicBrainzInterval.inMilliseconds * 3 / 1000;
    if (seconds < 90) return '${seconds.round()} seconds';
    return '${(seconds / 60).ceil()} minutes';
  }

  String _sourceLabel(ArtSource source) => switch (source) {
        ArtSource.alreadyPresent => 'already there',
        ArtSource.sibling => 'from another track',
        ArtSource.folderImage => 'from the folder image',
        ArtSource.downloaded => 'from the Cover Art Archive',
        ArtSource.needsLookup => 'nothing found',
      };
}
