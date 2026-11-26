import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';
import '../core/net.dart' show LookupStatus;
import '../core/tags.dart';
import 'tagger.dart';
import 'theme.dart';

enum SwipeAction { save, skip, batch }

class SwipeScreen extends StatefulWidget {
  const SwipeScreen({super.key, required this.tagger});
  final Tagger tagger;

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen>
    with SingleTickerProviderStateMixin {
  Tagger get t => widget.tagger;

  Offset _drag = Offset.zero;
  late final AnimationController _fly;
  Animation<Offset>? _flyAnim;
  bool _editorOpen = false;
  String? _shownMessage;
  final FocusNode _keys = FocusNode(debugLabel: 'swipe-keys');

  @override
  void initState() {
    super.initState();
    _fly = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(() {
        final a = _flyAnim;
        if (a != null) setState(() => _drag = a.value);
      });
    t.addListener(_onTagger);
    t.start();
  }

  @override
  void dispose() {
    t.removeListener(_onTagger);
    _fly.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _onTagger() {
    final m = t.message;
    if (m != null && m != _shownMessage && mounted) {
      _shownMessage = m;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(m),
          action: t.canUndo && !m.startsWith('Undone')
              ? SnackBarAction(label: 'Undo', onPressed: t.undo)
              : null,
        ));
    }
    if (mounted) setState(() {});
  }

  // ---- swiping -----------------------------------------------------------

  SwipeAction? _intent(Offset d) {
    if (d.dy < -90 && d.dy.abs() > d.dx.abs()) return SwipeAction.batch;
    if (d.dx > 90) return SwipeAction.save;
    if (d.dx < -90) return SwipeAction.skip;
    return null;
  }

  Future<void> _perform(SwipeAction a) async {
    if (t.busy || t.finished) return;
    final size = MediaQuery.of(context).size;
    final target = switch (a) {
      SwipeAction.save => Offset(size.width * 1.2, _drag.dy),
      SwipeAction.skip => Offset(-size.width * 1.2, _drag.dy),
      SwipeAction.batch => Offset(_drag.dx, -size.height),
    };
    _flyAnim = Tween(begin: _drag, end: target)
        .animate(CurvedAnimation(parent: _fly, curve: Curves.easeIn));
    await _fly.forward(from: 0);
    switch (a) {
      case SwipeAction.save:
        await t.accept();
      case SwipeAction.skip:
        await t.skip();
      case SwipeAction.batch:
        await t.batch();
    }
    if (mounted) setState(() => _drag = Offset.zero);
  }

  Future<void> _settle() async {
    _flyAnim = Tween(begin: _drag, end: Offset.zero)
        .animate(CurvedAnimation(parent: _fly, curve: Curves.easeOutBack));
    await _fly.forward(from: 0);
  }

  void _onPanEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    var intent = _intent(_drag);
    if (intent == null && v.distance > 900) {
      intent = _intent(v / 6);
    }
    if (intent == null) {
      _settle();
    } else {
      _perform(intent);
    }
  }

  // ---- keyboard ----------------------------------------------------------

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.widget is EditableText;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || _typing) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      t.undo();
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.enter) {
      _perform(SwipeAction.save);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _perform(SwipeAction.skip);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _perform(SwipeAction.batch);
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.backspace) {
      t.back();
    } else if (k == LogicalKeyboardKey.space) {
      t.togglePlay();
    } else if (k == LogicalKeyboardKey.keyE) {
      setState(() => _editorOpen = !_editorOpen);
    } else {
      final digit = int.tryParse(k.keyLabel);
      final cands = t.current?.candidates ?? const [];
      if (digit != null && digit >= 1 && digit <= cands.length) {
        t.choose(cands[digit - 1]);
      } else {
        return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.handled;
  }

  // ---- layout ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final folder = t.root.split('/').last;
    return Backdrop(
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              tooltip: 'Back to folders',
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Column(
              children: [
                const Text('mp3sorter',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Text(folder,
                    style: const TextStyle(
                        fontSize: 12, color: Palette.textDim)),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Undo last save (Ctrl+Z)',
                icon: const Icon(Icons.undo),
                onPressed: t.canUndo && !t.busy ? t.undo : null,
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'back') t.back();
                  if (v == 'keys') _showKeys();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'back', child: Text('Bring back last skipped')),
                  PopupMenuItem(value: 'keys', child: Text('Keyboard shortcuts')),
                ],
              ),
            ],
          ),
          body: t.finished ? _done() : _working(),
        ),
      ),
    );
  }

  void _showKeys() {
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(
        title: Text('Keyboard'),
        content: Text(
          '→ or Enter   save\n'
          '←            skip\n'
          '↑            save + album to rest of folder\n'
          '↓ or ⌫       bring back last skipped\n'
          'Space        play / pause\n'
          '1–9          pick a suggestion\n'
          'E            show / hide the fields\n'
          'Ctrl+Z       undo',
          style: TextStyle(fontFamily: 'monospace', height: 1.6),
        ),
      ),
    );
  }

  Widget _done() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Glass(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 48, color: Palette.save),
              const SizedBox(height: 12),
              const Text('Folder done',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('${t.doneCount} saved · ${t.skippedCount} skipped',
                  style: const TextStyle(color: Palette.textDim)),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (t.skippedCount > 0)
                    TextButton(
                      onPressed: t.back,
                      child: const Text('Revisit skipped'),
                    ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Choose another folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _working() {
    final c = t.current!;
    final intent = _intent(_drag);
    final total = t.queue.length;
    final position = total - t.pendingCount + 1;
    return LayoutBuilder(builder: (context, box) {
      final cardWidth = math.min(box.maxWidth * 0.68, 320.0);
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SizedBox(
            height: cardWidth * 1.42,
            child: _carousel(c, cardWidth, intent),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$position of $total'
              '${t.skippedCount > 0 ? ' · ${t.skippedCount} skipped' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.textDim, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _nowPlaying(c),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _Scrubber(tagger: t),
          ),
          _controls(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: _variations(c),
          ),
          if (_editorOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _Editor(
                key: ValueKey('${c.path}#${t.cardEpoch}'),
                draft: c.draft,
                onChanged: (f) {
                  t.edit(f);
                  setState(() {});
                },
              ),
            ),
        ],
      );
    });
  }

  Widget _carousel(CardData c, double width, SwipeAction? intent) {
    final prev = t.previousPath;
    final next = t.nextPath;
    final angle = _drag.dx / 900;
    final glow = switch (intent) {
      SwipeAction.save => Palette.save,
      SwipeAction.skip => Palette.skip,
      SwipeAction.batch => Palette.batch,
      null => null,
    };
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        if (prev != null)
          Positioned(
            right: null,
            left: -width * 0.62,
            child: Opacity(
              opacity: 0.45,
              child: Transform.scale(
                scale: 0.86,
                child: SizedBox(
                    width: width, child: _TrackCard(card: t.card(prev))),
              ),
            ),
          ),
        if (next != null)
          Positioned(
            right: -width * 0.62,
            child: Opacity(
              opacity: 0.45,
              child: Transform.scale(
                scale: 0.86,
                child: SizedBox(
                    width: width, child: _TrackCard(card: t.card(next))),
              ),
            ),
          ),
        Transform.translate(
          offset: _drag,
          child: Transform.rotate(
            angle: angle,
            child: RawGestureDetector(
              gestures: {
                _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
                  _EagerPan.new,
                  (r) => r
                    ..onUpdate = (d) {
                      if (!t.busy) setState(() => _drag += d.delta);
                    }
                    ..onEnd = (d) {
                      if (!t.busy) _onPanEnd(d);
                    },
                ),
              },
              child: SizedBox(
                width: width,
                child: Stack(
                  children: [
                    _TrackCard(card: c, glow: glow, live: true),
                    if (intent != null)
                      Positioned.fill(
                          child: _IntentStamp(
                              intent: intent, batchCount: t.batchIndexes.length)),
                    if (t.busy)
                      const Positioned.fill(
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _nowPlaying(CardData c) {
    final d = c.draft;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.title ?? splitPath(c.path).$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              Text(
                d.artist ?? 'Unknown artist',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textDim, fontSize: 15),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Edit fields (E)',
          icon: Icon(_editorOpen ? Icons.edit_off : Icons.edit,
              color: Palette.accent),
          onPressed: () => setState(() => _editorOpen = !_editorOpen),
        ),
      ],
    );
  }

  Widget _controls() {
    final canBatch = t.batchIndexes.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Skip (←)',
            iconSize: 30,
            color: Palette.skip,
            icon: const Icon(Icons.close_rounded),
            onPressed: t.busy ? null : () => _perform(SwipeAction.skip),
          ),
          IconButton(
            tooltip: 'Bring back last skipped (↓)',
            iconSize: 28,
            icon: const Icon(Icons.skip_previous_rounded),
            onPressed: t.busy ? null : t.back,
          ),
          StreamBuilder<bool>(
            stream: t.player.playingStream,
            builder: (context, snap) {
              final playing = snap.data ?? false;
              return GestureDetector(
                onTap: t.togglePlay,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFE6ECFF), Palette.accentDeep],
                    ),
                    boxShadow: [
                      BoxShadow(color: Color(0x66000000), blurRadius: 16),
                    ],
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 36,
                    color: Palette.bgBottom,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: canBatch
                ? 'Save + album to ${t.batchIndexes.length} more (↑)'
                : 'No more tracks in this folder',
            iconSize: 28,
            color: Palette.batch,
            icon: Badge(
              isLabelVisible: canBatch,
              label: Text('${t.batchIndexes.length}'),
              child: const Icon(Icons.library_add_check_outlined),
            ),
            onPressed: t.busy || !canBatch
                ? null
                : () => _perform(SwipeAction.batch),
          ),
          IconButton(
            tooltip: 'Save (→)',
            iconSize: 30,
            color: Palette.save,
            icon: const Icon(Icons.check_rounded),
            onPressed: t.busy ? null : () => _perform(SwipeAction.save),
          ),
        ],
      ),
    );
  }

  Widget _variations(CardData c) {
    final cands = c.candidates;
    final status = switch (c.lookup) {
      _ when c.lookingUp => const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2)),
      LookupStatus.offline || LookupStatus.rateLimited => TextButton.icon(
          onPressed: t.retryLookup,
          icon: const Icon(Icons.cloud_off, size: 16),
          label: Text(c.lookup == LookupStatus.offline ? 'Offline' : 'Busy'),
        ),
      LookupStatus.noMatch => const Text('No online match',
          style: TextStyle(color: Palette.textDim, fontSize: 12)),
      _ => const SizedBox.shrink(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Metadata Variations',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            status,
            const Spacer(),
            IconButton(
              tooltip: 'Fields (E)',
              icon: Icon(_editorOpen
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down),
              onPressed: () => setState(() => _editorOpen = !_editorOpen),
            ),
          ],
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cands.length + c.genres.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final cand =
                  i < cands.length ? cands[i] : c.genres[i - cands.length];
              final selected = identical(cand, c.chosen) ||
                  (c.chosen == null && cand.tags == c.draft);
              return Tooltip(
                message: [
                  cand.tags.artist,
                  cand.tags.title,
                  cand.detail,
                ].whereType<String>().where((s) => s.isNotEmpty).join('\n'),
                child: ChoiceChip(
                  selected: selected,
                  showCheckmark: false,
                  avatar: i < 9 && i < cands.length
                      ? Text('${i + 1}',
                          style: const TextStyle(
                              color: Palette.textDim, fontSize: 11))
                      : null,
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 230),
                    child: Text(_chipText(cand),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  onSelected: (_) => t.choose(cand),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _chipText(Candidate c) {
    return switch (c.source) {
      CandidateSource.musicBrainz =>
        c.tags.album == null ? c.label : '${c.label} · ${c.tags.album}',
      CandidateSource.lastFm => '# ${c.label}',
      _ => c.label,
    };
  }
}

/// A pan that claims the gesture the moment a finger lands on the card.
///
/// The screen scrolls vertically, and a plain pan loses every upward drag to
/// the scroll view — the swipe-up batch could never fire on a phone. Taking
/// the gesture eagerly means a drag that starts on the card is always the
/// card's; scrolling still works from anywhere else.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// The card itself: cover, then the tags as they will be written.
class _TrackCard extends StatelessWidget {
  const _TrackCard({required this.card, this.glow, this.live = false});
  final CardData card;
  final Color? glow;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final d = card.draft;
    final info = card.info;
    final secs = info?.durationSeconds;
    final source = card.chosen?.label ??
        (info != null && !info.tags.isEmpty ? 'As tagged' : 'Guessed');
    return Glass(
      glow: glow ?? (live ? Palette.accent.withValues(alpha: 0.6) : null),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.25,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (card.cover != null)
                    Image.memory(card.cover!.bytes,
                        fit: BoxFit.cover, gaplessPlayback: true)
                  else
                    Container(
                      color: const Color(0x22FFFFFF),
                      child: Icon(
                        card.fetchingCover
                            ? Icons.downloading
                            : Icons.music_note_rounded,
                        size: 56,
                        color: Palette.textDim,
                      ),
                    ),
                  if (card.addsCover)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _Badge(
                        text: card.coverSource == CoverSource.folder
                            ? 'Cover from folder · will embed'
                            : 'Cover Art Archive · will embed',
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          _line('Artist', d.artist),
          _line('Track', d.title ?? splitPath(card.path).$2),
          _line('Album', d.album),
          _line('Source', source),
          _line('Tags', d.genre),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(d.year?.toString() ?? '',
                  style: const TextStyle(color: Palette.textDim)),
              const Spacer(),
              if (secs != null)
                Text(_mmss(secs),
                    style: const TextStyle(color: Palette.textDim)),
            ],
          ),
          if (info?.readError != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text("Tags couldn't be read",
                  style: TextStyle(color: Palette.skip, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _line(String label, String? value) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: '$label: ', style: const TextStyle(color: Palette.textDim)),
        TextSpan(text: value ?? '—'),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13),
    );
  }
}

String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xAA0C1018),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _IntentStamp extends StatelessWidget {
  const _IntentStamp({required this.intent, required this.batchCount});
  final SwipeAction intent;
  final int batchCount;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (intent) {
      SwipeAction.save => ('SAVE', Palette.save),
      SwipeAction.skip => ('SKIP', Palette.skip),
      SwipeAction.batch => (
          batchCount == 0 ? 'SAVE' : 'ALBUM → +$batchCount',
          Palette.batch
        ),
    };
    return IgnorePointer(
      child: Center(
        child: Transform.rotate(
          angle: -0.2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 3),
              borderRadius: BorderRadius.circular(10),
              color: const Color(0x880C1018),
            ),
            child: Text(text,
                style: TextStyle(
                    color: color, fontSize: 26, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }
}

class _Scrubber extends StatelessWidget {
  const _Scrubber({required this.tagger});
  final Tagger tagger;

  @override
  Widget build(BuildContext context) {
    final p = tagger.player;
    return StreamBuilder<Duration?>(
      stream: p.durationStream,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: p.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble();
            final value =
                max <= 0 ? 0.0 : pos.inMilliseconds.clamp(0, max).toDouble();
            return Column(
              children: [
                Slider(
                  value: value,
                  max: max <= 0 ? 1 : max,
                  onChanged: max <= 0
                      ? null
                      : (v) => p.seek(Duration(milliseconds: v.round())),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Text(_mmss(pos.inSeconds),
                          style: const TextStyle(
                              color: Palette.textDim, fontSize: 12)),
                      const Spacer(),
                      const Icon(Icons.volume_down,
                          size: 16, color: Palette.textDim),
                      SizedBox(
                        width: 90,
                        child: Slider(
                          value: tagger.settings.volume,
                          onChanged: tagger.setVolume,
                        ),
                      ),
                      const Spacer(),
                      Text(_mmss(dur.inSeconds),
                          style: const TextStyle(
                              color: Palette.textDim, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The inline fields. Re-created (by key) whenever a chip is chosen or the
/// card changes, so they always start from the current draft.
class _Editor extends StatefulWidget {
  const _Editor({super.key, required this.draft, required this.onChanged});
  final TagSet draft;
  final void Function(TagSet Function(TagSet)) onChanged;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final Map<String, TextEditingController> _c = {
    'title': TextEditingController(text: widget.draft.title ?? ''),
    'artist': TextEditingController(text: widget.draft.artist ?? ''),
    'album': TextEditingController(text: widget.draft.album ?? ''),
    'albumArtist': TextEditingController(text: widget.draft.albumArtist ?? ''),
    'year': TextEditingController(text: widget.draft.year?.toString() ?? ''),
    'track':
        TextEditingController(text: widget.draft.trackNumber?.toString() ?? ''),
    'genre': TextEditingController(text: widget.draft.genre ?? ''),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  // A cleared field reads as "leave it", never as "erase it" — blank fields
  // are not written (see TagSet). So clearing uses null, and copyWith's
  // null-means-keep would hide that; rebuild the set explicitly instead.
  TagSet _rebuild(TagSet d, String key, String v) {
    final s = v.trim().isEmpty ? null : v.trim();
    final n = int.tryParse(v.trim());
    return TagSet(
      title: key == 'title' ? s : d.title,
      artist: key == 'artist' ? s : d.artist,
      album: key == 'album' ? s : d.album,
      albumArtist: key == 'albumArtist' ? s : d.albumArtist,
      year: key == 'year' ? n : d.year,
      trackNumber: key == 'track' ? n : d.trackNumber,
      genre: key == 'genre' ? s : d.genre,
    );
  }

  Widget _field(String key, String label, {bool number = false}) {
    return TextField(
      controller: _c[key],
      keyboardType: number ? TextInputType.number : TextInputType.text,
      inputFormatters:
          number ? [FilteringTextInputFormatter.digitsOnly] : null,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label),
      onChanged: (v) => widget.onChanged((d) => _rebuild(d, key, v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 10, width: 10);
    return Glass(
      child: Column(
        children: [
          _field('title', 'Title'),
          gap,
          _field('artist', 'Artist'),
          gap,
          _field('album', 'Album'),
          gap,
          _field('albumArtist', 'Album artist'),
          gap,
          Row(
            children: [
              Expanded(child: _field('year', 'Year', number: true)),
              gap,
              Expanded(child: _field('track', 'Track #', number: true)),
            ],
          ),
          gap,
          _field('genre', 'Genre'),
        ],
      ),
    );
  }
}
