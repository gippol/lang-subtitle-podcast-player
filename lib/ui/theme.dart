import 'package:flutter/material.dart';

/// モノクロ + 等幅フォントのコンソール風テーマ。
ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final fg = dark ? const Color(0xFFE6E6E6) : const Color(0xFF111111);
  final bg = dark ? const Color(0xFF0E0E0E) : const Color(0xFFFAFAFA);
  final muted = dark ? const Color(0xFF8A8A8A) : const Color(0xFF6E6E6E);
  final line = dark ? const Color(0xFF2E2E2E) : const Color(0xFFDDDDDD);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: fg,
    onPrimary: bg,
    secondary: muted,
    onSecondary: bg,
    error: fg,
    onError: bg,
    surface: bg,
    onSurface: fg,
    onSurfaceVariant: muted,
    outline: muted,
    outlineVariant: line,
    surfaceContainerHighest: line,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    fontFamily: 'monospace',
    splashFactory: NoSplash.splashFactory,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        fontFamily: 'monospace',
        color: fg,
        fontWeight: FontWeight.bold,
      ),
      shape: Border(bottom: BorderSide(color: line)),
    ),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(iconColor: muted, textColor: fg),
    sliderTheme: SliderThemeData(
      trackHeight: 2,
      activeTrackColor: fg,
      inactiveTrackColor: line,
      thumbColor: fg,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      padding: const EdgeInsets.symmetric(horizontal: kSliderPadding),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: bg,
      shape: Border(top: BorderSide(color: fg)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: fg,
      linearTrackColor: line,
    ),
  );
}

/// スライダー左右の余白 (A-B 区間の描画位置合わせに使う)
const double kSliderPadding = 12;
