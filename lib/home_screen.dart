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
import 'art_screen.dart';
import 'bitrate.dart';
import 'diagnostics_screen.dart';
import 'duplicates.dart';
import 'plan.dart';
import 'recent_folders.dart';
import 'quality_screen.dart';
import 'review_screen.dart';
import 'session_file.dart';

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

  Future<void> _scanPath(String path) async {
    if (!Directory(path).existsSync()) {
      // Almost always a removable card that is not in. Saying which is
      // the difference between plugging it back in and assuming the app
      // has lost the folder.
      _say('That folder is not there right now. If it is on an SD card, '
          'check the card is mounted.');
      return;
    }
    await _ensureStorageAccess();
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
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            tooltip: 'Bug report',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DiagnosticsScreen(app: app),
            )),
          ),
          if (app.canUndo)
            TextButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('Undo all changes'),
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
              if (app.scanIsStale && app.scan != null) _StaleCard(app: app),
              if (!app.scanIsStale && app.lastReuse != null)
                _ReuseLine(app: app),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: Text(app.rootPath ?? 'Choose a folder'),
                  subtitle: Text(app.rootPath == null
                      ? 'Nothing is read until you pick one'
                      : '${scan?.tracks.length ?? 0} files · '
                          'scanned in ${scan?.elapsed.inSeconds ?? 0}s'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (app.scan == null)
                        TextButton(
                          onPressed: _loadSession,
                          child: const Text('Load'),
                        ),
                      FilledButton(
                        onPressed: _pickFolder,
                        child:
                            Text(app.rootPath == null ? 'Choose' : 'Rescan'),
                      ),
                    ],
                  ),
                ),
              ),
              if (scan != null) ...[
                const SizedBox(height: 12),
                _SaveLoadRow(app: app, onMessage: _say),
                const SizedBox(height: 16),
                _QualityCard(app: app),
                const SizedBox(height: 12),
                _DuplicateCard(app: app),
                const SizedBox(height: 12),
                _ArtCard(app: app),
                const SizedBox(height: 12),
                _OptionsCard(app: app),
                const SizedBox(height: 16),
                _PlanCard(app: app),
                const SizedBox(height: 32),
              ] else ...[
                if (app.recentFolders.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _RecentFolders(app: app, onScan: _scanPath),
                ],
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

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadSession() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Load a saved scan',
      type: FileType.any,
    );
    if (picked.isEmpty) return;
    final path = picked.first.path;
    if (path == null) {
      _say('That file cannot be read directly. Copy it to local storage '
          'first.');
      return;
    }
    try {
      _say(await app.loadSession(path));
    } on SessionFormatException catch (e) {
      _say('Not a saved scan: ${e.message}');
    } catch (e) {
      _say('Could not load that: $e');
    }
  }

  Future<void> _confirmUndo() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo everything?'),
        content: const Text(
          'Reverses every change still in the journal, newest first — '
          'which is every run since the last undo, not only the most '
          'recent one. Files go back to the exact paths they came from, '
          'and anything in the trash folder comes back too.',
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

/// Shown when the scan no longer describes what is on disk.
///
/// The screen that would have prevented 249 identical failures: after a
/// run moves files, every path in the scan points at where they used to
/// be. Applying again fails on all of them with "file no longer exists",
/// which is true and tells you nothing.
/// Folders scanned before.
///
/// An entry whose folder is not currently mounted stays in the list and
/// is shown greyed rather than removed — on a removable card the path
/// disappears whenever the card is out, which is exactly when being able
/// to see it still matters.
class _RecentFolders extends StatelessWidget {
  const _RecentFolders({required this.app, required this.onScan});

  final AppState app;
  final Future<void> Function(String) onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text('Recent folders',
                style: theme.textTheme.titleMedium),
          ),
          for (final folder in app.recentFolders)
            _RecentRow(folder: folder, app: app, onScan: onScan),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.folder,
    required this.app,
    required this.onScan,
  });

  final RecentFolder folder;
  final AppState app;
  final Future<void> Function(String) onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Checked at render time, never used to prune the stored list.
    final available = Directory(folder.path).existsSync();

    return ListTile(
      dense: true,
      enabled: true,
      leading: Icon(
        available ? Icons.folder_outlined : Icons.sd_card_alert_outlined,
        color: available ? null : theme.disabledColor,
      ),
      title: Text(
        folder.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: available ? null : theme.disabledColor),
      ),
      subtitle: Text(
        available
            ? '${folder.parentLabel} · ${folder.fileCount} files'
            : '${folder.parentLabel} · not mounted',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: 'Forget this folder',
        onPressed: () => app.forgetFolder(folder.path),
      ),
      onTap: () => onScan(folder.path),
    );
  }
}

/// What the scan got for free.
///
/// Worth a line on screen because the behaviour is otherwise alarming: a
/// scan that used to take three minutes now finishes before the progress
/// bar has drawn, which reads as a scan that failed. Saying so is
/// cheaper than explaining it afterwards.
class _ReuseLine extends StatelessWidget {
  const _ReuseLine({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reuse = app.lastReuse!;
    if (reuse.total == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(
            reuse.everythingReused ? Icons.bolt : Icons.sync,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              reuse.describe(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (reuse.reused > 0)
            TextButton(
              // The escape hatch. Reuse rests on size and modification
              // time telling the truth about whether a file changed —
              // which is what make and rsync rest on — but a card
              // restored from a backup that preserved both would leave
              // the index describing files that are not what it thinks.
              onPressed: () => app.forceFullRescan(),
              child: const Text('Read everything again'),
            ),
        ],
      ),
    );
  }
}

class _StaleCard extends StatelessWidget {
  const _StaleCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history_toggle_off, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('This scan is out of date',
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Files may have moved since it was taken, so the plan could '
              'point at paths that are no longer there. Rescanning is now '
              'the cheap option — only the files that actually changed '
              'get read.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonal(
                  // A rescan rather than the old "do the paths still
                  // exist" pass. That pass existed because a real scan
                  // cost three minutes; with the index it costs about a
                  // second, and unlike the cheap check it also picks up
                  // files that changed rather than only ones that left.
                  onPressed: () async {
                    final root = app.rootPath;
                    if (root == null) return;
                    await app.scanFolder(root);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(app.lastReuse?.describe() ?? 'Rescanned.'),
                    ));
                  },
                  child: const Text('Rescan'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    final missing = await app.verifyPaths();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(missing == 0
                          ? 'All files are where the scan says.'
                          : '$missing files had moved and were dropped '
                              'from the plan.'),
                    ));
                  },
                  child: const Text('Just check they exist'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SaveLoadRow extends StatelessWidget {
  const _SaveLoadRow({required this.app, required this.onMessage});

  final AppState app;
  final void Function(String) onMessage;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('Save scan'),
            onPressed: () => _save(context, json: true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('Save report'),
            onPressed: () => _save(context, json: false),
          ),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context, {required bool json}) async {
    // Written beside the collection rather than through a save dialog:
    // the folder is already known to be writable, and a file next to the
    // music is easier to find again than one in a picker's idea of
    // "Documents".
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '')
        .replaceAll('-', '');
    final name = json
        ? 'mp3sorter-scan-$stamp.json'
        : 'mp3sorter-report-$stamp.txt';
    final path = '${app.rootPath}/$name';
    try {
      final written =
          json ? await app.saveSession(path) : await app.saveReport(path);
      onMessage(written == null ? 'Nothing to save' : 'Saved $name');
    } catch (e) {
      // The commonest cause by far on Android: a removable SD card, which
      // all-files access does not cover for writing.
      onMessage('Could not write there: $e');
    }
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

/// The way into art collection.
///
/// Its own card and its own screen rather than a checkbox in the
/// options, for two reasons: it is the one part of the app that can
/// reach a network, and it is applied as a separate run from the moves
/// — a cover goes beside the folder a file is in now, and a move changes
/// which folder that is.
class _ArtCard extends StatelessWidget {
  const _ArtCard({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = app.artSummary;

    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ArtScreen(app: app),
        )),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.album_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Album art', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      summary == null
                          ? 'Fill in missing covers from the album itself, '
                              'then optionally look the rest up online.'
                          : summary.allDone
                              ? 'Every album has a cover.'
                              : '${summary.filesMissing} files with no '
                                  'cover · ${summary.filesFixableOffline} '
                                  'fixable offline',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
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
              InkWell(
                onTap: (counts[band] ?? 0) == 0
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) =>
                              QualityBrowseScreen(app: app, band: band),
                        )),
                child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
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
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
              ),
            const SizedBox(height: 6),
            Text(
              'Computed from the file each scan, never written to it — '
              'your genres stay yours.',
              style: theme.textTheme.bodySmall,
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
            title: const Text('Reorganise files'),
            subtitle: const Text('Into a _sorted folder, never over the '
                'originals in place'),
            value: o.renameFiles,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: o.useFolderHints,
                layout: o.layout,
                renameFiles: v,
                writeTags: o.writeTags,
                cleanQualityTags: o.cleanQualityTags,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          if (o.renameFiles)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Layout'),
                  const SizedBox(height: 8),
                  SegmentedButton<Layout>(
                    segments: const [
                      ButtonSegment(
                          value: Layout.artistAlbumTitle,
                          label: Text('Artist/Album/Track')),
                      ButtonSegment(
                          value: Layout.artistTitle,
                          label: Text('Artist/Title')),
                    ],
                    selected: {o.layout},
                    onSelectionChanged: (sel) => app.setOptions(PlanOptions(
                        useFolderHints: o.useFolderHints,
                        layout: sel.first,
                        renameFiles: o.renameFiles,
                        writeTags: o.writeTags,
                        cleanQualityTags: o.cleanQualityTags,
                        standardiseArtists: o.standardiseArtists,
                        removeDuplicates: o.removeDuplicates)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A file with no album tag goes straight under the '
                    'artist. The folder a file is in now is never used '
                    'to guess — it is not a promise about what is '
                    'inside it.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          SwitchListTile(
            title: const Text('Use folder names when tags are missing'),
            subtitle: const Text('The folder above a file is read as the '
                'album and the one above that as the artist. Marked in '
                'the review as a guess.'),
            value: o.useFolderHints,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: v,
                layout: o.layout,
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                cleanQualityTags: o.cleanQualityTags,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Write tags'),
            value: o.writeTags,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: o.useFolderHints,
                layout: o.layout,
                renameFiles: o.renameFiles,
                writeTags: v,
                cleanQualityTags: o.cleanQualityTags,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Remove old quality tags'),
            subtitle: Text('Takes back the "$kLowQualityTag" genre that '
                'versions before 1.0.4 wrote. Quality is computed now, '
                'never stored.'),
            value: o.cleanQualityTags,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: o.useFolderHints,
                layout: o.layout,
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                cleanQualityTags: v,
                standardiseArtists: o.standardiseArtists,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Standardise artist spellings'),
            subtitle: const Text('Levenshtein matching across the whole '
                'collection'),
            value: o.standardiseArtists,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: o.useFolderHints,
                layout: o.layout,
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                cleanQualityTags: o.cleanQualityTags,
                standardiseArtists: v,
                removeDuplicates: o.removeDuplicates)),
          ),
          SwitchListTile(
            title: const Text('Remove duplicates'),
            subtitle: const Text('Moved to a trash folder, never deleted'),
            value: o.removeDuplicates,
            onChanged: (v) => app.setOptions(PlanOptions(
                useFolderHints: o.useFolderHints,
                layout: o.layout,
                renameFiles: o.renameFiles,
                writeTags: o.writeTags,
                cleanQualityTags: o.cleanQualityTags,
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
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: const Text('Open the full report'),
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DiagnosticsScreen(app: app),
                )),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
