/// Pick a folder, scan it, see what is there.
///
/// Deliberately does not offer an "apply" button. Applying lives behind
/// the review screen, because the whole premise is that nothing happens
/// to five thousand irreplaceable files without the list having been
/// looked at first.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_state.dart';
import 'bitrate.dart';
import 'duplicates.dart';
import 'plan.dart';
import 'review_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});

  final AppState app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onChange);
  }

  @override
  void dispose() {
    app.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Android will not let an app rename files across the user's storage
  /// without this, and the permission has to be granted from a settings
  /// screen rather than a dialog. Asked for only when a folder is being
  /// chosen, so the app does not open with a demand.
  Future<bool> _ensureStorageAccess() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;

    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Storage access needed'),
          content: const Text(
            'Renaming and retagging files across your storage needs the '
            '"All files access" permission. Android only grants it from '
            'its own settings screen.\n\n'
            'Without it the app can still scan and report, but cannot '
            'change anything.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () {
                openAppSettings();
                Navigator.of(context).pop();
              },
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  Future<void> _pickFolder() async {
    await _ensureStorageAccess();
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose your music folder',
    );
    if (path == null) return;
    await app.scanFolder(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scan = app.scan;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MP3 Sorter'),
        actions: [
          if (app.canUndo)
            TextButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('Undo last run'),
              onPressed: _confirmUndo,
            ),
        ],
      ),
      body: switch (app.stage) {
        Stage.scanning => _Busy(
            label: 'Scanning',
            detail: '${app.progressDone} files · ${app.progressLabel}',
          ),
        Stage.applying => _Busy(
            label: 'Applying',
            detail: '${app.progressDone} of ${app.progressTotal}',
            value: app.progressTotal == 0
                ? null
                : app.progressDone / app.progressTotal,
          ),
        _ => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (app.lastResult != null) _ResultCard(app: app),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text(app.rootPath ?? 'Choose a folder'),
                  subtitle: Text(app.rootPath == null
                      ? 'Nothing is read until you pick one'
                      : '${scan?.tracks.length ?? 0} files · '
                          'scanned in ${scan?.elapsed.inSeconds ?? 0}s'),
                  trailing: FilledButton(
                    onPressed: _pickFolder,
                    child: Text(app.rootPath == null ? 'Choose' : 'Rescan'),
                  ),
                ),
              ),
              if (scan != null) ...[
                const SizedBox(height: 16),
                _QualityCard(app: app),
                const SizedBox(height: 12),
                _DuplicateCard(app: app),
                const SizedBox(height: 12),
                _OptionsCard(app: app),
                const SizedBox(height: 16),
                _PlanCard(app: app),
                const SizedBox(height: 32),
              ] else ...[
                const SizedBox(height: 40),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Scanning only reads. Nothing is renamed, retagged '
                      'or removed until you have seen the full list and '
                      'said yes.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ],
          ),
      },
    );
  }

  Future<void> _confirmUndo() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo the last run?'),
        content: const Text(
          'Every move, retag and removal from the last run is reversed, '
          'newest first. Files in the trash folder come back to where '
          'they were.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Undo')),
        ],
      ),
    );
    if (yes == true) await app.undoEverything();
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label, required this.detail, this.value});

  final String label, detail;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 12),
            Text(detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _QualityCard extends StatelessWidget {
  const _QualityCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final counts = app.qualityCounts;
    final theme = Theme.of(context);
    final total = counts.values.fold(0, (a, b) => a + b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quality', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Read from the MPEG frame headers, not from the tags — tag '
              'libraries get this wrong.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final band in QualityBand.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _bandColour(band, theme),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(width: 92, child: Text(band.name)),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: total == 0
                              ? 0
                              : (counts[band] ?? 0) / total,
                          minHeight: 6,
                          color: _bandColour(band, theme),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('${counts[band] ?? 0}',
                          textAlign: TextAlign.right),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Color _bandColour(QualityBand b, ThemeData t) => switch (b) {
        QualityBand.low => t.colorScheme.error,
        QualityBand.acceptable => Colors.orange,
        QualityBand.good => Colors.lightGreen,
        QualityBand.high => Colors.green,
      };
}

class _DuplicateCard extends StatelessWidget {
  const _DuplicateCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final s = app.duplicateSummary;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Duplicates', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (s.isEmpty)
              const Text('None found.')
            else ...[
              Text('${s.groups} groups · ${s.removable} removable · '
                  '${(s.reclaimableBytes / 1073741824).toStringAsFixed(2)} GB'),
              const SizedBox(height: 8),
              for (final kind in DuplicateKind.values)
                Text(
                  '  ${_kindLabel(kind)}: '
                  '${app.duplicates.where((g) => g.kind == kind).length}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _kindLabel(DuplicateKind k) => switch (k) {
        DuplicateKind.identicalFile => 'identical files',
        DuplicateKind.sameAudio => 'same audio, different tags',
        DuplicateKind.sameSong => 'same song, different encodings',
      };
}

class _OptionsCard extends StatelessWidget {
  const _OptionsCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final o = app.options;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('File as Artist/Title'),
            subtitle: const Text('Into a _sorted folder, never over the '
                'originals in place'),
            value: o.renameFiles,
            onChanged: (v) => app.setOptions(PlanOptions(
                renameFiles: v,
                writeTags: o.writeTags,
                tagQuality: o.tagQuality,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Write tags'),
            value: o.writeTags,
            onChanged: (v) => app.setOptions(PlanOptions(
                renameFiles: o.renameFiles,
                writeTags: v,
                tagQuality: o.tagQuality,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Mark low quality'),
            subtitle: Text('Adds a "$kLowQualityTag" genre below '
                '${kLowQualityKbps}k'),
            value: o.tagQuality,
            onChanged: (v) => app.setOptions(PlanOptions(
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                tagQuality: v,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Standardise artist spellings'),
            subtitle: const Text('Levenshtein matching across the whole '
                'collection'),
            value: o.standardiseArtists,
            onChanged: (v) => app.setOptions(PlanOptions(
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                tagQuality: o.tagQuality,
                standardiseArtists: v,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Remove duplicates'),
            subtitle: const Text('Moved to a trash folder, never deleted'),
            value: o.removeDuplicates,
            onChanged: (v) => app.setOptions(PlanOptions(
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                tagQuality: o.tagQuality,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: v)),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final plan = app.plan;
    if (plan == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Proposed changes',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer)),
            const SizedBox(height: 8),
            _line(theme, '${plan.moves.length}', 'files moved or renamed'),
            _line(theme, '${plan.retags.length}', 'tag writes'),
            _line(theme, '${plan.trashes.length}', 'duplicates to trash'),
            _line(theme, '${plan.artistMerges.length}',
                'artist spellings merged'),
            _line(theme, '${plan.unsortable.length}',
                'left alone — not enough to go on'),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.fact_check_outlined),
                label: Text(plan.isEmpty
                    ? 'Nothing to do'
                    : 'Review ${plan.actionCount} changes'),
                onPressed: plan.isEmpty
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ReviewScreen(app: app),
                        )),
              ),
            ),
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
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onPrimaryContainer)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(what,
                  style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer)),
            ),
          ],
        ),
      );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final r = app.lastResult!;
    final theme = Theme.of(context);
    return Card(
      color: r.allSucceeded
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              r.allSucceeded
                  ? '${r.succeeded} changes applied'
                  : '${r.succeeded} applied, ${r.failed} failed',
              style: theme.textTheme.titleMedium,
            ),
            if (!r.allSucceeded) ...[
              const SizedBox(height: 8),
              // Named, not just counted. A run that says "12 failed"
              // without saying which is one you cannot act on.
              for (final e in r.errors.take(8))
                Text(e, style: theme.textTheme.bodySmall),
              if (r.errors.length > 8)
                Text('…and ${r.errors.length - 8} more',
                    style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
