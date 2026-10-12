/*
 * Liquid Glass theme.
 *
 * Builds the app-wide [ThemeData] so stock Material widgets we didn't touch
 * still look like they belong: translucent bars, capsule buttons, glass
 * dialogs, size-specific tracking, and the glass page transitions.
 */
import 'package:flutter/material.dart';

import 'glass_tokens.dart';
import 'glass_transitions.dart';

class LiquidGlassTheme {
  /// Backdrop behind the glass. Deliberately NOT flat: a soft vertical wash
  /// gives the blurred surfaces something to refract.
  static Color scaffoldBackground(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF0E0E11) : const Color(0xFFF2F2F7);

  /// Gradient painted behind the whole app (see [GlassBackdrop]).
  static LinearGradient backdropGradient(Brightness brightness, Color accent) {
    if (brightness == Brightness.dark) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF0E0E11),
          Color.alphaBlend(accent.withValues(alpha: 0.07), const Color(0xFF121216)),
          const Color(0xFF0B0B0E),
        ],
        stops: const [0.0, 0.5, 1.0],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        const Color(0xFFF7F7FB),
        Color.alphaBlend(accent.withValues(alpha: 0.055), const Color(0xFFEFEFF5)),
        const Color(0xFFF4F4F8),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
  }

  /// Type scale with size-specific tracking: tighten as text grows, leave
  /// small text slightly open for legibility over translucent material.
  static TextTheme textTheme(TextTheme base) => base.copyWith(
        displayLarge: base.displayLarge?.copyWith(letterSpacing: -1.2, height: 1.05, fontWeight: FontWeight.w700),
        displayMedium: base.displayMedium?.copyWith(letterSpacing: -0.9, height: 1.08, fontWeight: FontWeight.w700),
        displaySmall: base.displaySmall?.copyWith(letterSpacing: -0.7, height: 1.1, fontWeight: FontWeight.w600),
        headlineMedium: base.headlineMedium?.copyWith(letterSpacing: -0.5, fontWeight: FontWeight.w600),
        headlineSmall: base.headlineSmall?.copyWith(letterSpacing: -0.4, fontWeight: FontWeight.w600),
        titleLarge: base.titleLarge?.copyWith(letterSpacing: -0.35, fontWeight: FontWeight.w600),
        titleMedium: base.titleMedium?.copyWith(letterSpacing: -0.25, fontWeight: FontWeight.w600),
        titleSmall: base.titleSmall?.copyWith(letterSpacing: -0.15, fontWeight: FontWeight.w600),
        bodyLarge: base.bodyLarge?.copyWith(letterSpacing: -0.1, height: 1.4),
        bodyMedium: base.bodyMedium?.copyWith(letterSpacing: 0, height: 1.4),
        bodySmall: base.bodySmall?.copyWith(letterSpacing: 0.1, height: 1.35),
        labelLarge: base.labelLarge?.copyWith(letterSpacing: 0.1, fontWeight: FontWeight.w600),
        labelSmall: base.labelSmall?.copyWith(letterSpacing: 0.4),
      );

  /// Applies every glass-flavoured component theme onto an existing
  /// [ThemeData], preserving the app's own colour scheme and font work.
  static ThemeData apply(ThemeData theme) {
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    final palette = GlassPalette(brightness: brightness, accent: scheme.primary);

    return theme.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      // canvasColor is deliberately left alone: with `useMaterial3: false`
      // (a user-facing toggle in this app) Drawer and DropdownButton menus
      // paint from it, and a transparent value makes them unreadable.
      textTheme: textTheme(theme.textTheme),
      splashFactory: InkSparkle.splashFactory,
      dividerColor: palette.hairline,
      dividerTheme: DividerThemeData(color: palette.hairline, thickness: 0.5, space: 0.5),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: GlassPageTransitionsBuilder(),
        TargetPlatform.iOS: GlassPageTransitionsBuilder(),
        TargetPlatform.macOS: GlassPageTransitionsBuilder(),
        TargetPlatform.windows: GlassPageTransitionsBuilder(),
        TargetPlatform.linux: GlassPageTransitionsBuilder(),
      }),
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(size: 21, color: scheme.onSurface.withValues(alpha: 0.85)),
        actionsIconTheme: IconThemeData(size: 21, color: scheme.onSurface.withValues(alpha: 0.85)),
        titleTextStyle: textTheme(theme.textTheme).titleMedium?.copyWith(fontSize: 17),
      ),
      cardTheme: theme.cardTheme.copyWith(
        color: palette.fill,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.md)),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: isDark
            ? const Color(0xFF1C1C20).withValues(alpha: 0.94)
            : Colors.white.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.lg)),
        titleTextStyle: textTheme(theme.textTheme).titleMedium?.copyWith(fontSize: 17),
      ),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        // NOT transparent: the ~12 existing `showModalBottomSheet` call sites
        // supply no background of their own and would render see-through.
        // `showGlassSheet` opts out explicitly for the full glass treatment.
        backgroundColor: isDark
            ? const Color(0xFF1B1B1E).withValues(alpha: 0.96)
            : Colors.white.withValues(alpha: 0.96),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(GlassRadius.lg)),
        ),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        color: isDark ? const Color(0xFF1F1F23).withValues(alpha: 0.95) : Colors.white.withValues(alpha: 0.95),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GlassRadius.md),
          side: BorderSide(color: palette.hairline),
        ),
      ),
      tooltipTheme: theme.tooltipTheme.copyWith(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2F).withValues(alpha: 0.95) : const Color(0xFF32323A).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(GlassRadius.xs),
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
        waitDuration: const Duration(milliseconds: 500),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.capsule)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.capsule)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          backgroundColor: palette.fillInteractive,
          foregroundColor: scheme.primary,
          elevation: 0,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.capsule)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.capsule)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          side: BorderSide(color: palette.hairline),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.capsule)),
          highlightColor: scheme.primary.withValues(alpha: 0.10),
        ),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.72),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassRadius.sm),
          borderSide: BorderSide(color: palette.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassRadius.sm),
          borderSide: BorderSide(color: palette.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassRadius.sm),
          borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.6), width: 1.4),
        ),
        hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.4), fontSize: 14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? Colors.white : Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : (isDark ? Colors.white.withValues(alpha: 0.18) : Colors.black.withValues(alpha: 0.12))),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      listTileTheme: theme.listTileTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.sm)),
        iconColor: scheme.primary.withValues(alpha: 0.85),
      ),
      tabBarTheme: theme.tabBarTheme.copyWith(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurface.withValues(alpha: 0.55),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: -0.2),
        overlayColor: WidgetStateProperty.all(Colors.transparent),
      ),
      navigationRailTheme: theme.navigationRailTheme.copyWith(
        backgroundColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.14),
        elevation: 0,
      ),
      floatingActionButtonTheme: theme.floatingActionButtonTheme.copyWith(
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        backgroundColor: Colors.transparent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(5),
        radius: const Radius.circular(GlassRadius.capsule),
        thumbColor: WidgetStateProperty.all(scheme.onSurface.withValues(alpha: 0.22)),
      ),
      snackBarTheme: theme.snackBarTheme.copyWith(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF26262B) : const Color(0xFF2C2C33),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(GlassRadius.sm)),
        elevation: 0,
      ),
    );
  }
}

/// Paints the app-wide backdrop the glass refracts. Sits below everything in
/// the widget tree; all Scaffolds above it are transparent.
class GlassBackdrop extends StatelessWidget {
  final Widget child;

  const GlassBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LiquidGlassTheme.backdropGradient(theme.brightness, theme.colorScheme.primary),
      ),
      child: child,
    );
  }
}
