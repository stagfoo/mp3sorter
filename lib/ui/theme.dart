import 'package:flutter/material.dart';

/// Night-sky palette: deep slate behind, frosted glass on top, a pale
/// periwinkle for anything interactive.
class Palette {
  static const bgTop = Color(0xFF1B2433);
  static const bgBottom = Color(0xFF0C1018);
  static const glass = Color(0x1FFFFFFF);
  static const glassBorder = Color(0x33FFFFFF);
  static const accent = Color(0xFFB4C3F2);
  static const accentDeep = Color(0xFF7D8FD0);
  static const text = Color(0xFFF2F4F8);
  static const textDim = Color(0xFF9AA3B5);
  static const save = Color(0xFF7FD6A4);
  static const skip = Color(0xFFF08A8A);
  static const batch = Color(0xFFF2C46D);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Palette.accentDeep,
      brightness: Brightness.dark,
      surface: Palette.bgBottom,
      primary: Palette.accent,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: Palette.text,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Palette.glass,
      selectedColor: Palette.accent.withValues(alpha: 0.35),
      side: const BorderSide(color: Palette.glassBorder),
      shape: const StadiumBorder(),
      labelStyle: const TextStyle(color: Palette.text, fontSize: 13),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Palette.glass,
      labelStyle: TextStyle(color: Palette.textDim),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Palette.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Palette.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Palette.accent),
      ),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: Palette.accent,
      inactiveTrackColor: Palette.glassBorder,
      thumbColor: Palette.accent,
      trackHeight: 3,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
  );
}

/// The gradient every screen sits on.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Palette.bgTop, Palette.bgBottom],
        ),
      ),
      child: child,
    );
  }
}

/// A frosted panel.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = const EdgeInsets.all(14),
    this.glow,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  /// A coloured halo, used while a swipe is being decided.
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Palette.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: glow ?? Palette.glassBorder,
          width: glow == null ? 1 : 2,
        ),
        boxShadow: [
          if (glow != null)
            BoxShadow(color: glow!.withValues(alpha: 0.45), blurRadius: 24),
          const BoxShadow(
            color: Color(0x55000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}
