/*
 * Liquid Glass page transitions.
 *
 * Routes enter and exit along the SAME path (spatial consistency), the
 * outgoing page parallaxes back slightly instead of sitting still, and the
 * whole thing degrades to a cross-fade under reduced motion.
 */
import 'package:flutter/material.dart';

import 'glass_tokens.dart';

/// iOS-style push: new page slides in from the right over a parallaxing,
/// dimming parent. Dismiss mirrors the path exactly.
class GlassPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  GlassPageRoute({required this.page, super.settings})
      : super(
          transitionDuration: GlassDuration.page,
          reverseTransitionDuration: GlassDuration.medium,
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (GlassAccessibility.reduceMotion(context)) {
              return FadeTransition(opacity: animation, child: child);
            }

            final primary = CurvedAnimation(
              parent: animation,
              curve: GlassCurves.standard,
              reverseCurve: GlassCurves.standard.flipped,
            );
            final secondary = CurvedAnimation(parent: secondaryAnimation, curve: GlassCurves.standard);

            return SlideTransition(
              // Outgoing page drifts back ~30% — depth, not a hard swap.
              position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.28, 0)).animate(secondary),
              child: SlideTransition(
                position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(primary),
                child: FadeTransition(
                  opacity: Tween<double>(begin: 1, end: 0.6).animate(secondary),
                  child: child,
                ),
              ),
            );
          },
        );
}

/// Modal presentation: the sheet rises and materializes while the parent is
/// pushed back and dimmed.
class GlassModalRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  GlassModalRoute({required this.page, super.settings})
      : super(
          opaque: false,
          barrierColor: Colors.black26,
          transitionDuration: GlassDuration.medium,
          reverseTransitionDuration: GlassDuration.fast,
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (GlassAccessibility.reduceMotion(context)) {
              return FadeTransition(opacity: animation, child: child);
            }

            final curved = CurvedAnimation(
              parent: animation,
              curve: GlassCurves.enter,
              reverseCurve: GlassCurves.exit,
            );
            return SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(curved),
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                  child: child,
                ),
              ),
            );
          },
        );
}

/// Page transitions builder so every `MaterialPageRoute` in the app — including
/// ones we didn't touch — gets the glass motion for free.
class GlassPageTransitionsBuilder extends PageTransitionsBuilder {
  const GlassPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (GlassAccessibility.reduceMotion(context)) {
      return FadeTransition(opacity: animation, child: child);
    }

    final primary = CurvedAnimation(
      parent: animation,
      curve: GlassCurves.standard,
      reverseCurve: GlassCurves.standard.flipped,
    );
    final secondary = CurvedAnimation(parent: secondaryAnimation, curve: GlassCurves.standard);

    return SlideTransition(
      position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.25, 0)).animate(secondary),
      child: FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0.65).animate(secondary),
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(primary),
          child: child,
        ),
      ),
    );
  }
}

/// Shows a glass bottom sheet with a drag handle, rounded top corners and
/// a blurred backdrop.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  double? maxHeight,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    elevation: 0,
    builder: (context) {
      final media = MediaQuery.of(context);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight ?? media.size.height * 0.88),
          child: _GlassSheetFrame(child: builder(context)),
        ),
      );
    },
  );
}

class _GlassSheetFrame extends StatelessWidget {
  final Widget child;

  const _GlassSheetFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final radius = BorderRadius.vertical(top: Radius.circular(GlassRadius.lg));

    return ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: radius, boxShadow: palette.shadow(elevation: 1.6)),
        child: Stack(children: [
          // Glass body.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: ColoredBox(
                color: palette.isDark ? const Color(0xFF1B1B1E).withValues(alpha: 0.92) : Colors.white.withValues(alpha: 0.86),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            // Grab handle.
            Padding(
              padding: const EdgeInsets.only(top: 9, bottom: 3),
              child: Container(
                width: 38,
                height: 4.5,
                decoration: BoxDecoration(
                  color: palette.isDark ? Colors.white24 : Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(GlassRadius.capsule),
                ),
              ),
            ),
            Flexible(child: child),
          ]),
        ]),
      ),
    );
  }
}
