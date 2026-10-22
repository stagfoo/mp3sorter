/// Seeing exactly what would happen, before it does.
///
/// The screen the whole app is arranged around. Everything is listed,
/// everything can be turned off individually, and nothing is written
/// until the button at the bottom is pressed.
///
/// Actions start *accepted*. Making someone tick five thousand boxes to
/// approve a plan they agree with is how the review gets skipped — the
/// job here is spotting the handful that are wrong, not re-entering the
/// plan by hand.
library;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'crate_view.dart';
import 'plan.dart';
import 'sleeve_art.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.app});

  final AppState app;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  AppState get app => widget.app;

  /// Lives as long as the review, so covers seen once are not read from
  /// the files again on every flick through the crate.
  final _art = SleeveArt();

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

  @override
  Widget build(BuildContext context) {
    final plan = app.plan;
    if (plan == null) return const SizedBox.shrink();

    final approved = app.approved;
    final problems = validatePlan(approved);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Review'),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Moves (${plan.moves.length})'),
              Tab(text: 'Tags (${plan.retags.length})'),
              Tab(text: 'Trash (${plan.trashes.length})'),
              Tab(text: 'Skipped (${plan.unsortable.length})'),
            ],
          ),
        ),
        body: Column(
          children: [
            if (app.scanIsStale) const _StaleBar(),
            if (problems.isNotEmpty) _Problems(problems: problems),
            if (plan.artistMerges.isNotEmpty) _Merges(app: app),
            Expanded(
              child: TabBarView(
                children: [
                  CrateView(
                      app: app,
                      actions: plan.moves,
                      art: _art,
                      heroPrefix: 'moves',
                      part: (p) => p.moves),
                  CrateView(
                      app: app,
                      actions: plan.retags,
                      art: _art,
                      heroPrefix: 'tags',
                      part: (p) => p.retags),
                  _ActionList(app: app, actions: plan.trashes,
                      showTarget: false),
                  _Skipped(app: app),
                ],
              ),
            ),
            _ApplyBar(
              app: app,
              blocked: problems.isNotEmpty || app.scanIsStale,
              onApply: () => _confirm(context, approved),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context, Plan approved) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Apply ${approved.actionCount} changes?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${approved.moves.length} files moved\n'
                '${approved.retags.length} files retagged\n'
                '${approved.trashes.length} moved to the trash folder'),
            const SizedBox(height: 12),
            const Text(
              'Every change is recorded, and the whole run can be undone '
              'from the home screen. Nothing is deleted — removed '
              'duplicates go to a trash folder you can empty yourself.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply')),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    Navigator.of(context).pop();
    await app.applyApproved();
  }
}

/// The guard that stops a stale plan being applied.
///
/// Without it, re-applying after a run that moved files fails on every
/// action with "file no longer exists" — which is what happened on a
/// real device: 0 applied, 249 failed, and nothing on screen explaining
/// that the first run had already done the work.
class _StaleBar extends StatelessWidget {
  const _StaleBar();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.all(12),
      child: Text(
        'Files have moved since this scan was taken, so these paths are '
        'out of date. Go back and either check the files or rescan — '
        'applying now would fail on every one of them.',
        style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
      ),
    );
  }
}

class _Problems extends StatelessWidget {
  const _Problems({required this.problems});

  final List<PlanProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This plan cannot run as it stands',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onErrorContainer)),
          for (final p in problems.take(4))
            Text('· ${p.message} (${p.paths.length})',
                style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onErrorContainer)),
        ],
      ),
    );
  }
}

class _Merges extends StatelessWidget {
  const _Merges({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final merges = app.plan!.artistMerges;
    return ExpansionTile(
      leading: const Icon(Icons.merge_type),
      title: Text('${merges.length} artist spellings would be merged'),
      subtitle: const Text('The change most likely to be wrong — worth a '
          'look'),
      children: [
        for (final e in merges.entries)
          ListTile(
            dense: true,
            title: Text(e.key),
            subtitle: Text('← ${e.value.join("  ·  ")}'),
          ),
      ],
    );
  }
}

class _ActionList extends StatelessWidget {
  const _ActionList({
    required this.app,
    required this.actions,
    this.showTarget = false,
  });

  final AppState app;
  final List<PlannedAction> actions;
  final bool showTarget;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return const Center(child: Text('Nothing here.'));
    }
    final theme = Theme.of(context);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
                onPressed: () => app.acceptAll(actions),
                child: const Text('Accept all')),
            TextButton(
                onPressed: () => app.rejectAll(actions),
                child: const Text('Reject all')),
            const SizedBox(width: 8),
          ],
        ),
        Expanded(
          // Built lazily: five thousand rows materialised at once is how
          // the review screen becomes the slowest part of the app.
          child: ListView.builder(
            itemCount: actions.length,
            itemExtent: 76,
            itemBuilder: (context, i) {
              final a = actions[i];
              final rejected = app.isRejected(a);
              return CheckboxListTile(
                dense: true,
                value: !rejected,
                onChanged: (_) => app.toggle(a),
                title: Text(
                  a.path.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    decoration:
                        rejected ? TextDecoration.lineThrough : null,
                  ),
                ),
                subtitle: Text(
                  showTarget && a.targetPath != null
                      ? '→ ${a.targetPath!.split('/').reversed.take(2).toList().reversed.join("/")}'
                      : a.reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Skipped extends StatelessWidget {
  const _Skipped({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final skipped = app.plan!.unsortable;
    if (skipped.isEmpty) {
      return const Center(child: Text('Everything could be filed.'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'These have no artist to file under, so they are left exactly '
            'where they are. Guessing would overwrite the filename, which '
            'is the only clue they have left.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: skipped.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              title: Text(skipped[i].path.split('/').last,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(skipped[i].readError ?? 'no usable artist tag',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        ),
      ],
    );
  }
}

class _ApplyBar extends StatelessWidget {
  const _ApplyBar({
    required this.app,
    required this.blocked,
    required this.onApply,
  });

  final AppState app;
  final bool blocked;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final approved = app.approved;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${approved.actionCount} of ${app.plan!.actionCount} '
                'selected',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Apply'),
              onPressed:
                  blocked || approved.isEmpty ? null : onApply,
            ),
          ],
        ),
      ),
    );
  }
}
