import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// macOS-flavoured design tokens: neutral grays, system blue, hairline borders,
/// generous radii and almost no elevation.
class AppTheme {
  static const _accentLight = Color(0xFF007AFF);
  static const _accentDark = Color(0xFF0A84FF);

  static const radius = 14.0;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// Per-platform UI font. Flutter's own default on Windows is Segoe UI, which
  /// has no Han glyphs, so CJK text would fall back to whatever font the engine
  /// picks first (often not Microsoft YaHei). Naming the CJK fonts explicitly
  /// keeps Chinese text consistent.
  static ({String? family, List<String> fallback}) get fonts {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return (
          family: 'Segoe UI',
          fallback: const ['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI Emoji'],
        );
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return (
          family: '.AppleSystemUIFont',
          fallback: const ['PingFang SC', 'Hiragino Sans GB', 'Apple Color Emoji'],
        );
      case TargetPlatform.linux:
        return (
          family: null,
          fallback: const [
            'Noto Sans CJK SC',
            'Noto Sans SC',
            'WenQuanYi Micro Hei',
            'Source Han Sans SC',
          ],
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return (family: null, fallback: const ['Noto Sans CJK SC', 'Noto Sans SC']);
    }
  }

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final accent = isDark ? _accentDark : _accentLight;

    final surface = isDark ? const Color(0xFF2C2C2E) : Colors.white;
    final background = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final onSurface = isDark ? const Color(0xFFF2F2F7) : const Color(0xFF1D1D1F);
    final muted = isDark ? const Color(0xFF98989F) : const Color(0xFF6E6E73);
    final hairline = isDark ? const Color(0x24FFFFFF) : const Color(0x14000000);

    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      primary: accent,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: muted,
      surfaceContainerLowest: background,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFEDEDF0),
      surfaceContainerHighest: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA),
      secondaryContainer: accent.withValues(alpha: isDark ? 0.24 : 0.12),
      onSecondaryContainer: accent,
      outline: muted,
      outlineVariant: hairline,
      error: isDark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
    );

    final f = fonts;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: f.family,
      fontFamilyFallback: f.fallback,
    );

    // Tighter, calmer type scale than stock M3.
    final text = base.textTheme
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          titleSmall: base.textTheme.titleSmall?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13.5),
          bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
          labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 11),
        )
        .apply(bodyColor: onSurface, displayColor: onSurface);

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));

    return base.copyWith(
      textTheme: text,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      dividerColor: hairline,
      dividerTheme: DividerThemeData(color: hairline, space: 1, thickness: 1),
      splashFactory: NoSplash.splashFactory,
      highlightColor: onSurface.withValues(alpha: 0.04),
      hoverColor: onSurface.withValues(alpha: 0.04),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: hairline),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.titleLarge,
        foregroundColor: onSurface,
      ),
      listTileTheme: ListTileThemeData(iconColor: muted, shape: shape),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: hairline),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: accent.withValues(alpha: isDark ? 0.24 : 0.12),
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(
          text.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? accent : muted, size: 22),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFF2F2F7),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: text.titleSmall,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: BorderSide(color: hairline),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: text.titleSmall,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: text.titleSmall,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: hairline)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? accent.withValues(alpha: isDark ? 0.28 : 0.14)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accent : muted,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: text.labelLarge?.copyWith(fontSize: 12),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? const Color(0xFF34C759)
              : (isDark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6)),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF3A3A3C) : const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: text.bodySmall?.copyWith(color: Colors.white),
      ),
      visualDensity: VisualDensity.standard,
    );
  }
}

/// Remaining-quota color: green > 50%, amber > 20%, red otherwise.
/// Uses the Apple system palette.
Color quotaColor(double remaining, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  if (remaining > 50) return dark ? const Color(0xFF30D158) : const Color(0xFF34C759);
  if (remaining > 20) return dark ? const Color(0xFFFFD60A) : const Color(0xFFFF9500);
  return dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
}

/// Colors for stacked series (models / windows), in a fixed order. Ten
/// distinct hues of similar lightness that read on both light and dark cards;
/// neighbours differ strongly so the first few series are easy to tell apart.
const seriesPalette = [
  Color(0xFF3B82F6), // blue
  Color(0xFF10B981), // emerald
  Color(0xFFF59E0B), // amber
  Color(0xFF8B5CF6), // violet
  Color(0xFFF43F5E), // rose
  Color(0xFF06B6D4), // cyan
  Color(0xFFF97316), // orange
  Color(0xFF6366F1), // indigo
  Color(0xFFEC4899), // pink
  Color(0xFF84CC16), // lime
];

/// Color of the merged "Other" series.
const seriesOtherColor = Color(0xFF9CA3AF);
