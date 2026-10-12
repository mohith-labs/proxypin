/*
 * Liquid Glass design tokens.
 *
 * A single source of truth for the material, geometry, typography and motion
 * values used by the iOS "Liquid Glass" styled UI. Everything else in
 * `ui/component/liquid` reads from here, so the whole look can be retuned
 * from one file.
 */
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Geometry: Apple uses concentric, continuous (squircle) corners.
class GlassRadius {
  /// Chips, small controls.
  static const double xs = 10;

  /// Buttons, list rows.
  static const double sm = 14;

  /// Cards, grouped sections.
  static const double md = 20;

  /// Sheets, large panels.
  static const double lg = 28;

  /// Floating bars (fully rounded capsules use this as a cap).
  static const double capsule = 999;

  /// Corner radius of a child inset by [inset] inside a parent of [parent]
  /// radius, so corners stay concentric instead of drifting.
  static double concentric(double parent, double inset) =>
      (parent - inset).clamp(xs / 2, lg * 2).toDouble();
}

/// Blur strength per material weight. Bigger surfaces read as thicker glass.
class GlassBlur {
  /// Chips / small inline glass.
  static const double thin = 12;

  /// Default chrome: app bars, cards.
  static const double regular = 24;

  /// Sheets, dialogs, nav bars that float over content.
  static const double thick = 40;

  /// Full-screen scrims.
  static const double ultra = 60;
}

/// Durations. Deliberately short — Apple's chrome settles fast.
class GlassDuration {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 450);
  static const Duration page = Duration(milliseconds: 420);
}

/// Spring descriptions expressed in Apple's designer-facing parameters:
/// `response` (seconds to reach target) and `dampingRatio` (1.0 = no overshoot).
class GlassSprings {
  static SpringDescription of({double response = 0.4, double dampingRatio = 1.0, double mass = 1.0}) {
    final double stiffness = mass * math.pow(2 * math.pi / response, 2).toDouble();
    final double damping = 4 * math.pi * dampingRatio * mass / response;
    return SpringDescription(mass: mass, stiffness: stiffness, damping: damping);
  }

  /// Default UI spring: critically damped, graceful, never distracting.
  static final SpringDescription standard = of(response: 0.38, dampingRatio: 1.0);

  /// Momentum interactions (flick, drag release) — a little overshoot.
  static final SpringDescription bouncy = of(response: 0.35, dampingRatio: 0.78);

  /// Snappy press feedback.
  static final SpringDescription press = of(response: 0.22, dampingRatio: 0.9);

  /// Sheets and drawers.
  static final SpringDescription sheet = of(response: 0.3, dampingRatio: 0.82);
}

/// Easing curves used where a spring is overkill (non-gesture transitions).
class GlassCurves {
  /// iOS default ease — fast out, gentle settle.
  static const Curve standard = Cubic(0.32, 0.72, 0, 1);

  /// Mirror of [standard] for reversible transitions.
  static const Curve standardReverse = Cubic(1, 0, 0.68, 0.28);

  /// Entering content.
  static const Curve enter = Cubic(0.21, 0.9, 0.24, 1);

  /// Leaving content.
  static const Curve exit = Cubic(0.4, 0, 1, 1);

  /// Subtle overshoot for badges / pills.
  static const Curve overshoot = Cubic(0.17, 0.89, 0.32, 1.27);
}

/// The actual glass recipe: tint, borders, shadows, highlights.
///
/// Resolved from the ambient [ThemeData] so light/dark and the user's accent
/// colour both flow through automatically.
@immutable
class GlassPalette {
  final Brightness brightness;
  final Color accent;

  const GlassPalette({required this.brightness, required this.accent});

  factory GlassPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPalette(brightness: theme.brightness, accent: theme.colorScheme.primary);
  }

  bool get isDark => brightness == Brightness.dark;

  /// Base translucent fill of a glass surface.
  Color get fill => isDark ? const Color(0x40FFFFFF).withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.62);

  /// Heavier fill for structural regions (sidebars, nav bars).
  Color get fillStructural =>
      isDark ? Colors.white.withValues(alpha: 0.055) : Colors.white.withValues(alpha: 0.72);

  /// Lighter fill for interactive elements sitting on structural glass.
  Color get fillInteractive =>
      isDark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.82);

  /// Fill used when transparency is disabled by the OS accessibility setting.
  Color get fillOpaque => isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7FA);

  /// The bright edge where light catches the top of the material.
  Color get specularHigh => Colors.white.withValues(alpha: isDark ? 0.26 : 0.90);

  /// The dimmer bottom/outer edge.
  Color get specularLow => isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.30);

  /// Hairline separating glass from content.
  Color get hairline => isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.07);

  /// Inner glow that gives the material depth.
  Color get innerGlow => isDark ? Colors.white.withValues(alpha: 0.04) : Colors.white.withValues(alpha: 0.55);

  /// Shadow below a floating surface. Heavier for bigger surfaces.
  List<BoxShadow> shadow({double elevation = 1}) {
    final double a = isDark ? 0.42 : 0.12;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: a * 0.6),
        blurRadius: 10 * elevation,
        offset: Offset(0, 2 * elevation),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: a),
        blurRadius: 28 * elevation,
        spreadRadius: -4,
        offset: Offset(0, 10 * elevation),
      ),
    ];
  }

  /// Tinted glow used for "live"/active affordances (capture running, etc.).
  List<BoxShadow> accentGlow({double intensity = 1}) => [
        BoxShadow(
          color: accent.withValues(alpha: 0.35 * intensity),
          blurRadius: 24 * intensity,
          spreadRadius: 1 * intensity,
        ),
      ];

  /// Gradient across the face of the glass — brighter at the top-left.
  LinearGradient faceGradient({double strength = 1}) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: (isDark ? 0.10 : 0.45) * strength),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: (isDark ? 0.03 : 0.12) * strength),
        ],
        stops: const [0.0, 0.55, 1.0],
      );

  /// Edge gradient painted as a 1px border to fake specular reflection.
  LinearGradient edgeGradient() => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [specularHigh, specularLow, specularHigh.withValues(alpha: isDark ? 0.10 : 0.35)],
        stops: const [0.0, 0.5, 1.0],
      );
}

/// Accessibility signals that change how glass and motion are rendered.
class GlassAccessibility {
  /// Honour `prefers-reduced-motion` equivalents on every platform.
  static bool reduceMotion(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;
    return media.disableAnimations || media.accessibleNavigation;
  }

  /// Honour `prefers-reduced-transparency`: fall back to frosted-but-solid.
  static bool reduceTransparency(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return false;
    return media.highContrast;
  }
}
