/*
 * Liquid Glass interactions.
 *
 * Press feedback fires on pointer-DOWN (never on release), scales with a
 * spring, is interruptible, and is cancellable by dragging away. This is the
 * single most felt difference between "fine" and "fluid".
 */
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'glass_tokens.dart';

/// Wraps any widget with instant, spring-backed press feedback.
///
/// - highlight appears on pointer-down, not on tap-up
/// - scale animates with a critically damped spring, interruptible mid-flight
/// - dragging off the target cancels; dragging back re-arms it
/// - optional selection haptic fires on the same frame as the visual commit
class PressableGlass extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureLongPressStartCallback? onLongPressStart;

  /// How far the element shrinks while held. 1.0 = no scale.
  final double pressedScale;

  /// Opacity applied while held, on top of the scale.
  final double pressedOpacity;

  /// Overlay colour washed over the child while held.
  final Color? highlightColor;
  final BorderRadius? borderRadius;
  final bool haptics;
  final bool enabled;

  const PressableGlass({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onLongPressStart,
    this.pressedScale = 0.97,
    this.pressedOpacity = 1.0,
    this.highlightColor,
    this.borderRadius,
    this.haptics = true,
    this.enabled = true,
  });

  @override
  State<PressableGlass> createState() => _PressableGlassState();
}

class _PressableGlassState extends State<PressableGlass> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(vsync: this, value: 0);
  bool _down = false;
  Offset? _downPosition;

  /// Cached in didChangeDependencies: reading MediaQuery from a pointer
  /// callback can happen after this element is deactivated, which throws.
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = GlassAccessibility.reduceMotion(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Always animates from the *current* on-screen value, so an interrupted
  /// press never jumps.
  void _springTo(double target) {
    if (_reduceMotion) {
      _controller.value = target;
      return;
    }
    _controller.animateWith(
      SpringSimulation(GlassSprings.press, _controller.value, target, _controller.velocity),
    );
  }

  void _setDown(bool down) {
    if (_down == down || !mounted) return;
    _down = down;
    _springTo(down ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final palette = GlassPalette.of(context);
    final highlight = widget.highlightColor ??
        (palette.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.045));

    // Listener drives the VISUALS: it fires on the raw pointer event, with no
    // gesture-arena deadline in the way, so feedback is truly instant.
    // GestureDetector still owns tap/long-press semantics (and arena rules).
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _downPosition = event.position;
        _setDown(true);
      },
      onPointerMove: (event) {
        // Cancel by dragging away (with ~18px of slop), re-arm on return.
        final start = _downPosition;
        if (start == null) return;
        _setDown((event.position - start).distance < 18);
      },
      onPointerUp: (_) {
        _downPosition = null;
        _setDown(false);
      },
      onPointerCancel: (_) {
        _downPosition = null;
        _setDown(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptics) HapticFeedback.selectionClick();
                widget.onTap!.call();
              },
        onLongPress: widget.onLongPress,
        onLongPressStart: widget.onLongPressStart,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _controller.value.clamp(0.0, 1.2);
            final scale = 1 - (1 - widget.pressedScale) * t;
            return Transform.scale(
              scale: scale,
              child: Opacity(
                opacity: 1 - (1 - widget.pressedOpacity) * t.clamp(0.0, 1.0),
                child: Stack(children: [
                  child!,
                  if (t > 0.01)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: highlight.withValues(alpha: highlight.a * t.clamp(0.0, 1.0)),
                            borderRadius: widget.borderRadius ?? BorderRadius.circular(GlassRadius.sm),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Momentum projection — where a flick would come to rest, using Apple's
/// exponential-decay model (NOT the textbook v²/2a form).
double projectMomentum(double velocity, {double decelerationRate = 0.998}) {
  return (velocity / 1000.0) * decelerationRate / (1 - decelerationRate);
}

/// Progressive resistance past a boundary, instead of a hard stop.
double rubberband(double overshoot, double dimension, {double constant = 0.55}) {
  if (dimension <= 0) return overshoot;
  return (overshoot * dimension * constant) / (dimension + constant * overshoot.abs());
}

/// Staggered entrance for list items: each row fades + rises slightly, offset
/// by its index. Caps the stagger so long lists don't crawl.
class StaggeredEntrance extends StatefulWidget {
  final Widget child;
  final int index;
  final Duration duration;
  final Duration stagger;
  final int maxStaggerSteps;
  final double offsetY;

  const StaggeredEntrance({
    super.key,
    required this.child,
    required this.index,
    this.duration = GlassDuration.medium,
    this.stagger = const Duration(milliseconds: 24),
    this.maxStaggerSteps = 8,
    this.offsetY = 14,
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.duration);
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    final steps = widget.index.clamp(0, widget.maxStaggerSteps);
    final delay = widget.stagger * steps;
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      // A real Timer, not Future.delayed: it must be cancellable, or a row
      // scrolled out of view before its turn leaves a pending timer behind
      // (and calls setState on a disposed State).
      _delay = Timer(delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (GlassAccessibility.reduceMotion(context)) return widget.child;

    final curved = CurvedAnimation(parent: _controller, curve: GlassCurves.enter);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(offset: Offset(0, widget.offsetY * (1 - curved.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// A soft, slowly breathing glow used to signal a live/running state
/// (capture active). Deliberately slow and low-contrast.
class PulsingGlow extends StatefulWidget {
  final Widget child;
  final Color color;
  final bool active;
  final double radius;

  const PulsingGlow({
    super.key,
    required this.child,
    required this.color,
    this.active = true,
    this.radius = 14,
  });

  @override
  State<PulsingGlow> createState() => _PulsingGlowState();
}

class _PulsingGlowState extends State<PulsingGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulsingGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.animateTo(0, duration: GlassDuration.fast);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || GlassAccessibility.reduceMotion(context)) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.18 + 0.22 * t),
                blurRadius: widget.radius * (0.7 + 0.5 * t),
                spreadRadius: 1 + 1.5 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Animated number/text swap that slides the old value out and the new one in
/// along the same axis — spatially consistent, never a blind cross-fade.
class GlassAnimatedSwitcher extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final Axis axis;

  const GlassAnimatedSwitcher({
    super.key,
    required this.child,
    this.duration = GlassDuration.fast,
    this.axis = Axis.vertical,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: GlassCurves.enter,
      switchOutCurve: GlassCurves.exit,
      transitionBuilder: (child, animation) {
        if (GlassAccessibility.reduceMotion(context)) {
          return FadeTransition(opacity: animation, child: child);
        }
        final begin = axis == Axis.vertical ? const Offset(0, 0.35) : const Offset(0.35, 0);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: begin, end: Offset.zero).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
