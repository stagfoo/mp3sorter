/// The plan as a crate of records, rather than a list of filenames.
///
/// Three levels, each one a decision a person can actually make:
///
/// * **The crate** — every artist, as a stack of sleeves. Flick through
///   it; swipe one sideways to take that artist out of the plan.
/// * **The dial** — one artist in the middle, their records around them.
///   Hold a record to leave it alone.
/// * **The sleeve** — one record's tracks, each showing where it is now
///   and where it would go, individually tickable.
///
/// Nothing on these screens changes a file. They only edit the same
/// rejected-set the old list did, so the apply bar, the confirmation
/// and the undo journal are exactly as they were.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'plan.dart';
import 'shelf.dart';
import 'sleeve_art.dart';

/// Takes [actions] out of the plan, or puts them back, with a way to
/// change your mind. Swipes and long-presses are easy to do by accident,
/// and on five hundred files an accident should cost one tap to undo.
void _flipGroup(BuildContext context, AppState app,
    List<PlannedAction> actions, String label) {
  final before = {for (final a in actions) if (app.isRejected(a)) a};
  final takingOut = inclusionOf(actions, app.isRejected) != Inclusion.none;
  if (takingOut) {
    app.rejectAll(actions);
  } else {
    app.acceptAll(actions);
  }
  HapticFeedback.mediumImpact();
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 3),
    content: Text(takingOut
        ? '$label left alone'
        : '$label back in the plan'),
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () {
        app.acceptAll(actions);
        app.rejectAll(before);
      },
    ),
  ));
}

String _artistLabel(String? name) => name ?? 'No artist';
String _albumLabel(AlbumShelf a) => a.title ?? 'Loose tracks';

int _toCheck(Iterable<PlannedAction> actions) =>
    actions.where((a) => a.reason.contains('check this one')).length;

String _plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

// ------------------------------------------------------------- the crate

class CrateView extends StatefulWidget {
  const CrateView({
    super.key,
    required this.app,
    required this.actions,
    required this.art,
    required this.heroPrefix,
  });

  final AppState app;
  final List<PlannedAction> actions;
  final SleeveArt art;

  /// Keeps sleeve animations apart when two crates exist at once, as
  /// they do for a moment while the tabs slide.
  final String heroPrefix;

  @override
  State<CrateView> createState() => _CrateViewState();
}

class _CrateViewState extends State<CrateView>
    with AutomaticKeepAliveClientMixin {
  static const double _extent = 116;

  final _scroll = ScrollController();
  List<PlannedAction>? _shelvedFrom;
  List<ArtistShelf> _shelves = const [];
  String _query = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<ArtistShelf> get _visible {
    if (!identical(_shelvedFrom, widget.actions)) {
      _shelvedFrom = widget.actions;
      _shelves = shelve(widget.actions);
    }
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _shelves;
    return [
      for (final s in _shelves)
        if ((s.name ?? '').toLowerCase().contains(q) ||
            s.albums.any((a) => (a.title ?? '').toLowerCase().contains(q)))
          s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final app = widget.app;
    if (widget.actions.isEmpty) {
      return const Center(child: Text('Nothing here.'));
    }
    final shelves = _visible;
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Find an artist or album',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  onChanged: (v) {
                    setState(() => _query = v);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              ),
              PopupMenuButton<bool>(
                tooltip: 'Everything',
                icon: const Icon(Icons.more_vert),
                onSelected: (keep) => keep
                    ? app.acceptAll(widget.actions)
                    : app.rejectAll(widget.actions),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: true, child: Text('Keep everything')),
                  PopupMenuItem(
                      value: false, child: Text('Leave everything alone')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            '${_plural(shelves.length, 'artist')} · tap to open · '
            'swipe sideways to leave one alone',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: shelves.isEmpty
              ? const Center(child: Text('No artist or album matches.'))
              : LayoutBuilder(builder: (context, box) {
                  // The record in focus sits a quarter of the way down
                  // rather than in the middle: the crate opens with
                  // the first artist already in focus, and centring it
                  // left half the screen empty above it.
                  final h = box.maxHeight;
                  final focus = h / 4;
                  final top = math.max(0.0, focus - _extent / 2);
                  return ListView.builder(
                    controller: _scroll,
                    itemExtent: _extent,
                    padding: EdgeInsets.only(
                        top: top,
                        bottom: math.max(0, h - focus - _extent / 2)),
                    itemCount: shelves.length,
                    itemBuilder: (context, i) => AnimatedBuilder(
                      animation: _scroll,
                      builder: (context, child) {
                        final offset =
                            _scroll.hasClients ? _scroll.offset : 0.0;
                        final centre = top + i * _extent + _extent / 2 - offset;
                        // Normalised to the longer side, so records lean
                        // the same amount per step above and below.
                        final d = ((centre - focus) / (h - focus))
                            .clamp(-1.2, 1.2);
                        return _tilt(d, child!);
                      },
                      child: _ArtistRecord(
                        app: app,
                        shelf: shelves[i],
                        art: widget.art,
                        heroTag: '${widget.heroPrefix}:${shelves[i].key}',
                      ),
                    ),
                  );
                }),
        ),
      ],
    );
  }

  /// The stack: records near the middle face you, ones further away
  /// lean back and shrink, like the spines of a crate seen from above.
  Widget _tilt(double d, Widget child) {
    final distance = d.abs();
    final scale = 1 - 0.28 * math.min(distance, 1);
    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(-d * 0.75)
      ..scaleByDouble(scale, scale, 1, 1);
    return Opacity(
      opacity: (1 - 0.55 * math.min(distance, 1)).clamp(0.0, 1.0),
      child: Transform(
        alignment: Alignment.center,
        transform: transform,
        child: child,
      ),
    );
  }
}

class _ArtistRecord extends StatefulWidget {
  const _ArtistRecord({
    required this.app,
    required this.shelf,
    required this.art,
    required this.heroTag,
  });

  final AppState app;
  final ArtistShelf shelf;
  final SleeveArt art;
  final String heroTag;

  @override
  State<_ArtistRecord> createState() => _ArtistRecordState();
}

class _ArtistRecordState extends State<_ArtistRecord>
    with SingleTickerProviderStateMixin {
  static const double _pullOut = 80;

  late final AnimationController _settle = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(() => setState(() =>
        _dx = _from * (1 - Curves.easeOut.transform(_settle.value))));
  double _dx = 0;
  double _from = 0;

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails d) {
    _settle.stop();
    setState(() => _dx += d.delta.dx);
  }

  /// Springs back into the crate either way; past the line, the artist
  /// changes sides on the way.
  void _release() {
    final pulled = _dx.abs() > _pullOut;
    _from = _dx;
    _settle.forward(from: 0);
    if (pulled) {
      _flipGroup(context, widget.app, widget.shelf.actions,
          _artistLabel(widget.shelf.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final shelf = widget.shelf;
    final theme = Theme.of(context);
    final state = inclusionOf(shelf.actions, app.isRejected);
    final out = state == Inclusion.none;
    final kept = shelf.actions.where((a) => !app.isRejected(a)).length;
    final check = _toCheck(shelf.actions);
    final pulling = (_dx.abs() / _pullOut).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Most artists in a real collection have one record — 320 of 398
      // in the one this was built against — and a dial with one spoke
      // is a screen spent saying nothing. Those open straight onto the
      // tracks.
      onTap: () => shelf.albums.length == 1
          ? showTracksSheet(
              context,
              app: app,
              art: widget.art,
              album: shelf.albums.single,
              title: _albumLabel(shelf.albums.single),
              subtitle: _artistLabel(shelf.name),
              actions: shelf.actions,
            )
          : Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ArtistDialPage(
                app: app,
                shelf: shelf,
                art: widget.art,
                heroTag: widget.heroTag,
              ),
            )),
      onHorizontalDragUpdate: _drag,
      onHorizontalDragEnd: (_) => _release(),
      onHorizontalDragCancel: _release,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: Opacity(
          opacity: out ? 0.45 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Hero(
                  tag: widget.heroTag,
                  child: _SleeveFan(
                    albums: shelf.albums,
                    art: widget.art,
                    size: 92,
                    grey: out,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _artistLabel(shelf.name),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontStyle:
                              shelf.name == null ? FontStyle.italic : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_plural(shelf.albums.length, 'record')} · '
                        '${_plural(shelf.actions.length, 'file')}',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (state != Inclusion.all || check > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            switch (state) {
                              Inclusion.none => 'left alone',
                              Inclusion.some =>
                                '$kept of ${shelf.actions.length} kept',
                              Inclusion.all => '$check guessed from folders',
                            },
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: state == Inclusion.all
                                    ? theme.colorScheme.tertiary
                                    : theme.colorScheme.secondary),
                          ),
                        ),
                    ],
                  ),
                ),
                // What letting go of the swipe will do, shown while it
                // is being done.
                Opacity(
                  opacity: pulling,
                  child: Icon(
                    out ? Icons.add_circle_outline : Icons.block,
                    color: out
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to three of an artist's sleeves, fanned like records pulled half
/// out of a crate.
class _SleeveFan extends StatelessWidget {
  const _SleeveFan({
    required this.albums,
    required this.art,
    required this.size,
    this.grey = false,
  });

  final List<AlbumShelf> albums;
  final SleeveArt art;
  final double size;
  final bool grey;

  @override
  Widget build(BuildContext context) {
    final shown = albums.take(3).toList();
    final step = size * 0.22;
    return SizedBox(
      width: size + step * 2,
      height: size,
      child: Stack(
        children: [
          for (var i = shown.length - 1; i >= 0; i--)
            Positioned(
              left: step * i,
              top: 0,
              child: Sleeve(
                album: shown[i],
                art: art,
                size: size,
                grey: grey,
              ),
            ),
        ],
      ),
    );
  }
}

/// One record: its cover on a disc, or a disc made from its name when
/// there is no cover to show.
class Sleeve extends StatelessWidget {
  const Sleeve({
    super.key,
    required this.album,
    required this.art,
    required this.size,
    this.grey = false,
    this.ring,
  });

  final AlbumShelf album;
  final SleeveArt art;
  final double size;
  final bool grey;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final generated = _GeneratedSleeve(label: album.title ?? album.artist ?? '?');
    Widget disc = FutureBuilder(
      future: art.coverFor(
          album.key, [for (final a in album.actions) a.path]),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return generated;
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          // Decoded at the size it is shown. A 1400px cover decoded in
          // full, times a crate of them, is what gets an app killed.
          cacheWidth: (size * dpr).round(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => generated,
        );
      },
    );
    if (grey) {
      disc = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          0.2126, 0.7152, 0.0722, 0, 0, //
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: disc,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
            color: ring ?? Colors.black.withValues(alpha: 0.55),
            width: ring == null ? 1.5 : 3),
        boxShadow: const [
          BoxShadow(blurRadius: 8, offset: Offset(0, 3), color: Colors.black45),
        ],
      ),
      child: ClipOval(child: disc),
    );
  }
}

class _GeneratedSleeve extends StatelessWidget {
  const _GeneratedSleeve({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final hue = (label.toLowerCase().hashCode % 360).abs().toDouble();
    final a = HSLColor.fromAHSL(1, hue, 0.45, 0.32).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.55, 0.18).toColor();
    final words = label
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && RegExp(r'\w').hasMatch(w[0]))
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(colors: [a, b], radius: 0.9),
      ),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.6,
          child: FittedBox(
            child: Text(
              words.isEmpty ? '♪' : words,
              style: const TextStyle(
                  color: Colors.white70, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- the dial

class ArtistDialPage extends StatelessWidget {
  const ArtistDialPage({
    super.key,
    required this.app,
    required this.shelf,
    required this.art,
    required this.heroTag,
  });

  final AppState app;
  final ArtistShelf shelf;
  final SleeveArt art;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final state = inclusionOf(shelf.actions, app.isRejected);
        return Scaffold(
          appBar: AppBar(
            title: Text(_artistLabel(shelf.name)),
            actions: [
              Switch(
                value: state != Inclusion.none,
                onChanged: (_) => _flipGroup(context, app, shelf.actions,
                    _artistLabel(shelf.name)),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: shelf.albums.length > 24
                      ? _AlbumGrid(app: app, shelf: shelf, art: art)
                      : _Dial(
                          app: app, shelf: shelf, art: art, heroTag: heroTag),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    'Tap a record to see its tracks · hold it to leave it '
                    'alone · tap the middle for everything',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The artist in the middle and their records around them.
class _Dial extends StatelessWidget {
  const _Dial({
    required this.app,
    required this.shelf,
    required this.art,
    required this.heroTag,
  });

  final AppState app;
  final ArtistShelf shelf;
  final SleeveArt art;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final albums = shelf.albums;
    final n = albums.length;

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      final centre = Offset(w / 2, h / 2);
      const label = 34.0;

      // An oval, not a circle: a phone held upright is twice as tall as
      // it is wide, and a circle sized to the width crowds a dozen
      // records into the middle third of the screen.
      double perimeter(double a, double b) =>
          math.pi * (3 * (a + b) - math.sqrt((3 * a + b) * (a + 3 * b)));
      (double, double) radii(double size, double scale) => (
            (w / 2 - size / 2 - 16) * scale,
            (h / 2 - size / 2 - label) * scale,
          );

      // One ring while each record gets room for its sleeve and its
      // name; two once it would not.
      var rings = 1;
      var size = 0.0;
      for (rings = 1; rings <= 2; rings++) {
        final perRing = (n / rings).ceil();
        size = 96;
        for (var pass = 0; pass < 3; pass++) {
          final (rx, ry) = radii(size, rings == 2 ? 0.55 : 1);
          size = (perimeter(rx, ry) / math.max(perRing, 3) * 0.72)
              .clamp(48.0, 104.0);
        }
        // Two rings also need to clear each other.
        if (rings == 2) {
          final (ox, _) = radii(size, 1);
          size = math.min(size, ox * 0.42);
        }
        if (size >= 64 || rings == 2) break;
      }
      final albumSize = size;
      final perRing = (n / rings).ceil();
      final (outerX, outerY) = radii(albumSize, 1);
      final (innerX, innerY) = radii(albumSize, 0.55);
      final hubSize = rings == 2
          ? (innerX * 2 - albumSize - 20).clamp(56.0, 132.0)
          : (outerX * 2 - albumSize - 40).clamp(64.0, 168.0);

      // Spaced by distance along the oval, not by angle. Equal angles
      // on an oval bunch up at its narrow ends — top and bottom here —
      // which is exactly where the records were overlapping.
      final outerRing = _ovalSlots(perRing, outerX, outerY, 0);
      final innerRing = rings == 2
          ? _ovalSlots(n - perRing, innerX, innerY, 0.5)
          : const <Offset>[];

      Offset place(int i, double t) {
        final spot = rings == 2 && i.isOdd
            ? innerRing[i ~/ 2]
            : outerRing[rings == 2 ? i ~/ 2 : i];
        return centre + spot * t;
      }

      return TweenAnimationBuilder<double>(
        // The records spin out from the artist as the page opens.
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutBack,
        builder: (context, t, _) {
          final points = [for (var i = 0; i < n; i++) place(i, t)];
          final states = [
            for (final a in albums) inclusionOf(a.actions, app.isRejected),
          ];
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _Spokes(
                    centre: centre,
                    points: points,
                    states: states,
                    on: theme.colorScheme.primary,
                    off: theme.colorScheme.outlineVariant,
                  ),
                ),
              ),
              Positioned(
                left: centre.dx - hubSize / 2,
                top: centre.dy - hubSize / 2,
                child: GestureDetector(
                  onTap: () => showTracksSheet(
                    context,
                    app: app,
                    art: art,
                    album: albums.first,
                    title: _artistLabel(shelf.name),
                    subtitle: _plural(shelf.actions.length, 'file'),
                    actions: shelf.actions,
                  ),
                  child: Hero(
                    tag: heroTag,
                    child: Sleeve(
                      album: albums.first,
                      art: art,
                      size: hubSize,
                      grey: states.every((s) => s == Inclusion.none),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < n; i++)
                Positioned(
                  left: points[i].dx - (albumSize + 28) / 2,
                  top: points[i].dy - albumSize / 2,
                  width: albumSize + 28,
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: _DialRecord(
                      app: app,
                      album: albums[i],
                      art: art,
                      size: albumSize,
                      state: states[i],
                      artistName: _artistLabel(shelf.name),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    });
  }
}

/// [count] points evenly spaced along an oval of radii [rx] and [ry],
/// starting at the top, shifted round by [phase] of a gap.
List<Offset> _ovalSlots(int count, double rx, double ry, double phase) {
  if (count <= 0) return const [];
  const samples = 720;
  final points = [
    for (var i = 0; i <= samples; i++)
      Offset(math.cos(-math.pi / 2 + 2 * math.pi * i / samples) * rx,
          math.sin(-math.pi / 2 + 2 * math.pi * i / samples) * ry),
  ];
  final along = <double>[0];
  for (var i = 1; i <= samples; i++) {
    along.add(along.last + (points[i] - points[i - 1]).distance);
  }
  final total = along.last;
  final slots = <Offset>[];
  var j = 0;
  for (var k = 0; k < count; k++) {
    final want = ((k + phase) / count) * total;
    while (j < samples && along[j + 1] < want) {
      j++;
    }
    slots.add(points[j]);
  }
  return slots;
}

class _DialRecord extends StatelessWidget {
  const _DialRecord({
    required this.app,
    required this.album,
    required this.art,
    required this.size,
    required this.state,
    required this.artistName,
  });

  final AppState app;
  final AlbumShelf album;
  final SleeveArt art;
  final double size;
  final Inclusion state;
  final String artistName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = switch (state) {
      Inclusion.all => theme.colorScheme.primary,
      Inclusion.some => theme.colorScheme.tertiary,
      Inclusion.none => theme.colorScheme.outlineVariant,
    };
    return GestureDetector(
      onTap: () => showTracksSheet(
        context,
        app: app,
        art: art,
        album: album,
        title: _albumLabel(album),
        subtitle: artistName,
        actions: album.actions,
      ),
      onLongPress: () =>
          _flipGroup(context, app, album.actions, _albumLabel(album)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: state == Inclusion.none ? 0.5 : 1,
            child: Sleeve(
              album: album,
              art: art,
              size: size,
              grey: state == Inclusion.none,
              ring: ring,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _albumLabel(album),
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontStyle: album.isLoose ? FontStyle.italic : null,
              decoration:
                  state == Inclusion.none ? TextDecoration.lineThrough : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Spokes extends CustomPainter {
  _Spokes({
    required this.centre,
    required this.points,
    required this.states,
    required this.on,
    required this.off,
  });

  final Offset centre;
  final List<Offset> points;
  final List<Inclusion> states;
  final Color on;
  final Color off;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < points.length; i++) {
      final kept = states[i] != Inclusion.none;
      canvas.drawLine(
        centre,
        points[i],
        Paint()
          ..color = (kept ? on : off).withValues(alpha: kept ? 0.55 : 0.35)
          ..strokeWidth = kept ? 2 : 1,
      );
    }
  }

  @override
  bool shouldRepaint(_Spokes old) => true;
}

/// For an artist with more records than a dial can hold legibly.
class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.app, required this.shelf, required this.art});

  final AppState app;
  final ArtistShelf shelf;
  final SleeveArt art;

  @override
  Widget build(BuildContext context) {
    return GridView.extent(
      maxCrossAxisExtent: 120,
      padding: const EdgeInsets.all(12),
      childAspectRatio: 0.75,
      children: [
        for (final a in shelf.albums)
          _DialRecord(
            app: app,
            album: a,
            art: art,
            size: 88,
            state: inclusionOf(a.actions, app.isRejected),
            artistName: _artistLabel(shelf.name),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ the sleeve

/// One record's tracks — where each file is now, and where it would go.
Future<void> showTracksSheet(
  BuildContext context, {
  required AppState app,
  required SleeveArt art,
  required AlbumShelf album,
  required String title,
  required String subtitle,
  required List<PlannedAction> actions,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final theme = Theme.of(context);
          final state = inclusionOf(actions, app.isRejected);
          return CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Sleeve(album: album, art: art, size: 72),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            Text(subtitle, style: theme.textTheme.bodySmall),
                            const SizedBox(height: 6),
                            state == Inclusion.none
                                ? FilledButton.tonal(
                                    onPressed: () => _flipGroup(
                                        context, app, actions, title),
                                    child: const Text('Put back in the plan'),
                                  )
                                : OutlinedButton(
                                    onPressed: () => _flipGroup(
                                        context, app, actions, title),
                                    child: const Text('Leave all of these alone'),
                                  ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: actions.length,
                itemBuilder: (context, i) =>
                    _TrackRow(app: app, action: actions[i]),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    ),
  );
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.app, required this.action});

  final AppState app;
  final PlannedAction action;

  /// The tail of a path — enough to recognise where something is,
  /// short enough to fit on a phone.
  static String _tail(String path, int parts) {
    final bits = path.split('/');
    return bits.sublist(math.max(0, bits.length - parts)).join('/');
  }

  /// Where a file would go, from the artist folder down. Everything
  /// above that is the same for every file, so it is noise here.
  static String _filedAs(PlannedAction a) {
    final target = a.targetPath!;
    final artist = a.shelfArtist;
    if (artist != null) {
      final i = target.indexOf('/$artist/');
      if (i >= 0) return target.substring(i + 1);
    }
    return _tail(target, 3);
  }

  @override
  Widget build(BuildContext context) {
    final a = action;
    final theme = Theme.of(context);
    final rejected = app.isRejected(a);
    final small = theme.textTheme.bodySmall;
    final faint = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final flagged = a.reason.contains('check this one');

    final lines = <Widget>[
      if (a.kind == ActionKind.move) ...[
        Text('now  ${_tail(a.path, 2)}',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: faint),
        Text('to   ${_filedAs(a)}',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: small),
      ] else ...[
        Text(_tail(a.path, 2),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: faint),
        if (a.kind == ActionKind.trash && a.targetPath != null)
          Text('to the trash folder', style: small),
      ],
      if (a.reason.isNotEmpty && (a.kind != ActionKind.move || flagged))
        Text(
          a.reason,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: small?.copyWith(
              color: flagged ? theme.colorScheme.tertiary : null),
        ),
    ];

    return CheckboxListTile(
      value: !rejected,
      onChanged: (_) => app.toggle(a),
      title: Text(
        (a.targetPath ?? a.path).split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            decoration: rejected ? TextDecoration.lineThrough : null),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
      isThreeLine: true,
    );
  }
}
