import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/store.dart';
import 'swipe_screen.dart';
import 'tagger.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Directory? _appDir;
  Settings? _settings;
  Journal? _journal;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dir = await getApplicationSupportDirectory();
    final settings = await Settings.load(dir);
    final journal = await Journal.load(dir);
    if (!mounted) return;
    setState(() {
      _appDir = dir;
      _settings = settings;
      _journal = journal;
    });
  }

  /// Retagging files anywhere in shared storage needs "All files access",
  /// which Android only grants from its own settings screen. Asked for when
  /// a folder is opened, not at launch.
  Future<bool> _ensureStorageAccess() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Storage access needed'),
        content: const Text(
          'Writing tags into your music files needs the "All files access" '
          'permission. Android only grants it from its own settings screen.',
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
    return false;
  }

  Future<void> _pick() async {
    if (!await _ensureStorageAccess()) return;
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a folder to tag',
    );
    if (path != null) await _open(path);
  }

  Future<void> _open(String path) async {
    if (!Directory(path).existsSync()) {
      _say('That folder is not there right now — if it is on an SD card, '
          'check the card is mounted.');
      return;
    }
    if (!await _ensureStorageAccess()) return;
    final settings = _settings!;
    setState(() => _opening = true);
    try {
      final tagger = await Tagger.open(
        appDir: _appDir!,
        settings: settings,
        journal: _journal!,
        root: path,
      );
      settings.touchFolder(path);
      await settings.save();
      if (!mounted) return;
      if (tagger.queue.isEmpty) {
        tagger.dispose();
        _say('No audio files in that folder.');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SwipeScreen(tagger: tagger),
      ));
      tagger.dispose();
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _editLastFmKey() async {
    final settings = _settings!;
    final controller = TextEditingController(text: settings.lastFmKey);
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Last.fm API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Optional. Adds genre suggestions from Last.fm tags. '
              'Get a free key at last.fm/api.',
              style: TextStyle(color: Palette.textDim),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (key == null) return;
    settings.lastFmKey = key;
    await settings.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Backdrop(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('mp3sorter',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        body: settings == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Glass(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Swipe through a folder and fix its tags.',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 10),
                        const _Legend(
                            icon: Icons.arrow_forward,
                            color: Palette.save,
                            text: 'Right — save the tags'),
                        const _Legend(
                            icon: Icons.arrow_back,
                            color: Palette.skip,
                            text: 'Left — skip, leave the file alone'),
                        const _Legend(
                            icon: Icons.arrow_upward,
                            color: Palette.batch,
                            text: 'Up — save, and give the rest of the folder '
                                'this album'),
                        const SizedBox(height: 6),
                        const Text(
                          'Only the fields you change are written. Covers '
                          'and other tags already in a file are kept, and '
                          'every save can be undone.',
                          style:
                              TextStyle(color: Palette.textDim, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _opening ? null : _pick,
                            icon: _opening
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.folder_open),
                            label: const Text('Choose a folder'),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Include subfolders'),
                          value: settings.includeSubfolders,
                          onChanged: (v) async {
                            setState(() => settings.includeSubfolders = v);
                            await settings.save();
                          },
                        ),
                      ],
                    ),
                  ),
                  if (settings.recentFolders.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 24, 4, 8),
                      child: Text('Recent',
                          style: TextStyle(color: Palette.textDim)),
                    ),
                    for (final f in settings.recentFolders)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Glass(
                          padding: EdgeInsets.zero,
                          radius: 16,
                          child: ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(f.split('/').last),
                            subtitle: Text(f,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Palette.textDim, fontSize: 12)),
                            onTap: _opening ? null : () => _open(f),
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: const Text('Last.fm genres'),
                    subtitle: Text(
                      settings.lastFmKey.isEmpty
                          ? 'Off — add an API key to get genre suggestions'
                          : 'On',
                      style: const TextStyle(color: Palette.textDim),
                    ),
                    onTap: _editLastFmKey,
                  ),
                ],
              ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
