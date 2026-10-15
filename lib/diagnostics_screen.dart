/// The bug report, on screen, with a copy button.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'diagnostics.dart';

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final report = app.bugReport();
    final grouped = summariseErrors(app.lastResult?.errors ?? const []);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bug report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy everything',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Copied. Paste it wherever you need it.'),
              ));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (grouped.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What went wrong',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      // The useful summary: a thousand of one problem is
                      // one problem, and the count per cause is what says
                      // which.
                      'Failures grouped by cause, not by file.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    for (final e in grouped.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('${e.value} ×  ${e.key}',
                            style: theme.textTheme.bodyMedium),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.copy_all),
            label: const Text('Copy the whole report'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Copied.'),
              ));
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.save_alt),
            label: const Text('Save it beside the music'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final where = await app.saveBugReport();
              messenger.showSnackBar(SnackBar(
                content: Text(where == null
                    ? 'Could not write it there'
                    : 'Saved ${where.split('/').last}'),
              ));
            },
          ),
          const SizedBox(height: 16),
          // Selectable, so a part of it can be grabbed without taking
          // the lot.
          SelectableText(
            report,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
