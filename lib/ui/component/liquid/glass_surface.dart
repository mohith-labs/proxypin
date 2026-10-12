/*
 * Liquid Glass surfaces.
 *
 * `GlassSurface` is the one primitive every other glass widget is built from:
 * a blurred, tinted layer with a specular edge and a depth shadow. It degrades
 * to a solid frosted fill when the OS asks for reduced transparency.
 */
import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass_tokens.dart';

/// Material weight — controls blur radius and how much tint is applied.
enum GlassWeight {
  /// Inline chips and small controls.
  thin,

  /// Default: cards, app bars.
  regular,

  /// Floating chrome: nav bars, sheets, dialogs.
  thick,

  /// Structural regions: sidebars, side rails.
  structural,
}

extension on GlassWeight {
  double get blur => switch (this) {
        GlassWeight.thin => GlassBlur.thin,
        GlassWeight.regular => GlassBlur.regular,
        GlassWeight.thick => GlassBlur.thick,
        GlassWeight.structural => GlassBlur.thick,
      };

  double get elevation => switch (this) {
        GlassWeight.thin => 0.4,
        GlassWeight.regular => 0.8,
        GlassWeight.thick => 1.4,
        GlassWeight.structural => 0.6,
      };
}

/// A translucent, blurred surface with a specular edge.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final GlassWeight weight;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// Extra tint blended into the glass (e.g. the accent colour for an
  /// active state). Kept very low alpha — colour belongs on a solid layer.
  final Color? tint;

  /// Multiplier on the drop shadow. 0 disables it entirely.
  final double elevation;

  /// Draw the hairline/specular border.
  final bool border;

  /// Paint the diagonal face gradient that makes the surface read as glass.
  final bool specular;

  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;

  const GlassSurface({
    super.key,
    required this.child,
    this.weight = GlassWeight.regular,
    this.borderRadius,
    this.padding,
    this.margin,
    this.tint,
    this.elevation = 1,
    this.border = true,
    this.specular = true,
    this.width,
    this.height,
    this.alignment,
    this.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final radius = borderRadius ?? BorderRadius.circular(GlassRadius.md);
    final bool solid = GlassAccessibility.reduceTransparency(context);

    Color fill = switch (weight) {
      GlassWeight.thin => palette.fill.withValues(alpha: palette.fill.a * 0.75),
      GlassWeight.regular => palette.fill,
      GlassWeight.thick => palette.fillStructural,
      GlassWeight.structural => palette.fillStructural,
    };
    if (solid) fill = palette.fillOpaque;
    if (tint != null) fill = Color.alphaBlend(tint!.withValues(alpha: palette.isDark ? 0.18 : 0.12), fill);

    Widget content = Container(
      width: width,
      height: height,
      alignment: alignment,
      constraints: constraints,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        gradient: specular && !solid ? palette.faceGradient() : null,
      ),
      foregroundDecoration: border
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: solid ? palette.hairline : palette.specularHigh.withValues(alpha: palette.isDark ? 0.14 : 0.55),
                width: 0.8,
              ),
            )
          : null,
      child: child,
    );

    if (!solid) {
      content = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: weight.blur, sigmaY: weight.blur),
          child: content,
        ),
      );
    } else {
      content = ClipRRect(borderRadius: radius, child: content);
    }

    if (elevation > 0) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: palette.shadow(elevation: weight.elevation * elevation),
        ),
        child: content,
      );
    }

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }
    return content;
  }
}

/// A glass surface that animates its blur and scale on appear, so it reads as
/// a material arriving rather than a plain opacity fade ("materialize").
class MaterializingGlass extends StatefulWidget {
  final Widget child;
  final GlassWeight weight;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final Duration duration;
  final double elevation;

  const MaterializingGlass({
    super.key,
    required this.child,
    this.weight = GlassWeight.thick,
    this.borderRadius,
    this.padding,
    this.duration = GlassDuration.medium,
    this.elevation = 1,
  });

  @override
  State<MaterializingGlass> createState() => _MaterializingGlassState();
}

class _MaterializingGlassState extends State<MaterializingGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (GlassAccessibility.reduceMotion(context)) {
      return GlassSurface(
        weight: widget.weight,
        borderRadius: widget.borderRadius,
        padding: widget.padding,
        elevation: widget.elevation,
        child: widget.child,
      );
    }

    final curved = CurvedAnimation(parent: _controller, curve: GlassCurves.enter);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) {
        final t = curved.value;
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.94 + 0.06 * t,
            child: GlassSurface(
              weight: widget.weight,
              borderRadius: widget.borderRadius,
              padding: widget.padding,
              elevation: widget.elevation * t,
              child: child!,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Fades content into floating chrome instead of drawing a hard 1px divider —
/// Apple's "scroll edge effect". Wrap a scrollable; the top/bottom few pixels
/// blur and fade where they pass under the bar.
class ScrollEdgeFade extends StatelessWidget {
  final Widget child;
  final double topExtent;
  final double bottomExtent;

  const ScrollEdgeFade({super.key, required this.child, this.topExtent = 18, this.bottomExtent = 0});

  @override
  Widget build(BuildContext context) {
    if (topExtent <= 0 && bottomExtent <= 0) return child;

    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      if (!h.isFinite || h <= 0) return child;

      final stops = <double>[0.0, (topExtent / h).clamp(0.0, 0.4), 1 - (bottomExtent / h).clamp(0.0, 0.4), 1.0];
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            topExtent > 0 ? Colors.transparent : Colors.white,
            Colors.white,
            Colors.white,
            bottomExtent > 0 ? Colors.transparent : Colors.white,
          ],
          stops: stops,
        ).createShader(rect),
        child: child,
      );
    });
  }
}

/// Dim + push-back scrim for modal glass. Pairs with [MaterializingGlass] so a
/// modal task reads as "the background moved away", not "a box appeared".
class GlassScrim extends StatelessWidget {
  final Animation<double> animation;
  final VoidCallback? onDismiss;
  final double opacity;

  const GlassScrim({super.key, required this.animation, this.onDismiss, this.opacity = 0.32});

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        return GestureDetector(
          onTap: onDismiss,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 6 * t, sigmaY: 6 * t),
            child: Container(
              color: (palette.isDark ? Colors.black : const Color(0xFF1B1B1F)).withValues(alpha: opacity * t),
            ),
          ),
        );
      },
    );
  }
}
