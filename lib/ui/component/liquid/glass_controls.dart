/*
 * Liquid Glass chrome: nav bars, app bars, buttons, chips, sheets.
 *
 * These are drop-in replacements for the Material widgets the app used before,
 * keeping the same call shape so screens change as little as possible.
 */
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'glass_interactions.dart';
import 'glass_surface.dart';
import 'glass_tokens.dart';

/// One destination in [LiquidGlassNavBar].
class GlassNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final String? tooltip;

  const GlassNavItem({required this.icon, this.selectedIcon, required this.label, this.tooltip});
}

/// Floating capsule tab bar with a sliding "liquid" selection pill.
///
/// The pill springs between destinations (position is spring-driven, so a
/// rapid double-tap retargets smoothly instead of restarting), the selected
/// icon scales up slightly, and the whole bar is a thick glass material with
/// content scrolling underneath.
class LiquidGlassNavBar extends StatefulWidget {
  final List<GlassNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Show text labels under the icons.
  final bool showLabels;

  const LiquidGlassNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.showLabels = false,
  });

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar> with SingleTickerProviderStateMixin {
  late final AnimationController _pill =
      AnimationController.unbounded(vsync: this, value: widget.currentIndex.toDouble());

  @override
  void didUpdateWidget(covariant LiquidGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      final target = widget.currentIndex.toDouble();
      if (GlassAccessibility.reduceMotion(context)) {
        _pill.value = target;
      } else {
        // Retarget from the live value + velocity: no brick wall on reversal.
        _pill.animateWith(SpringSimulation(GlassSprings.standard, _pill.value, target, _pill.velocity));
      }
    }
  }

  @override
  void dispose() {
    _pill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset > 0 ? 6 : 10),
      child: GlassSurface(
        weight: GlassWeight.thick,
        borderRadius: BorderRadius.circular(widget.showLabels ? GlassRadius.lg : GlassRadius.capsule),
        height: widget.showLabels ? 66 : 58,
        child: LayoutBuilder(builder: (context, constraints) {
          final n = widget.items.length;
          final slot = constraints.maxWidth / n;

          return Stack(children: [
            // Sliding selection pill.
            AnimatedBuilder(
              animation: _pill,
              builder: (context, _) {
                final v = _pill.value.clamp(0.0, (n - 1).toDouble());
                return Positioned(
                  left: slot * v + 6,
                  top: 6,
                  bottom: 6,
                  width: slot - 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: palette.isDark ? 0.26 : 0.16),
                      borderRadius: BorderRadius.circular(widget.showLabels ? GlassRadius.sm : GlassRadius.capsule),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: palette.isDark ? 0.34 : 0.22),
                        width: 0.8,
                      ),
                    ),
                  ),
                );
              },
            ),
            Row(
              children: List.generate(n, (i) {
                final item = widget.items[i];
                return Expanded(
                  child: AnimatedBuilder(
                    animation: _pill,
                    builder: (context, _) {
                      // Proximity to the pill drives icon scale + colour, so
                      // the whole row responds continuously, not in a step.
                      final distance = (_pill.value - i).abs().clamp(0.0, 1.0);
                      final t = 1 - distance;
                      final color = Color.lerp(
                        theme.colorScheme.onSurface.withValues(alpha: 0.55),
                        theme.colorScheme.primary,
                        t,
                      )!;

                      return PressableGlass(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onTap(i);
                        },
                        pressedScale: 0.9,
                        haptics: false,
                        borderRadius: BorderRadius.circular(GlassRadius.capsule),
                        child: Tooltip(
                          message: item.tooltip ?? item.label,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Transform.scale(
                                scale: 1 + 0.12 * t,
                                child: Icon(
                                  t > 0.5 ? (item.selectedIcon ?? item.icon) : item.icon,
                                  size: 23,
                                  color: color,
                                ),
                              ),
                              if (widget.showLabels) ...[
                                const SizedBox(height: 3),
                                Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w500),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              }),
            ),
          ]);
        }),
      ),
    );
  }
}

/// Translucent app bar that content scrolls underneath.
class LiquidGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool centerTitle;
  final double height;
  final bool automaticallyImplyLeading;
  final Widget? bottom;
  final double bottomHeight;
  final SystemUiOverlayStyle? systemOverlayStyle;

  const LiquidGlassAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.centerTitle = true,
    this.height = 48,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.bottomHeight = 0,
    this.systemOverlayStyle,
  });

  @override
  Size get preferredSize => Size.fromHeight(height + bottomHeight);

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final theme = Theme.of(context);

    return AppBar(
      title: title,
      actions: actions,
      leading: leading,
      centerTitle: centerTitle,
      toolbarHeight: height,
      automaticallyImplyLeading: automaticallyImplyLeading,
      systemOverlayStyle: systemOverlayStyle,
      // The glass itself; AppBar just hosts it.
      flexibleSpace: GlassSurface(
        weight: GlassWeight.thick,
        borderRadius: BorderRadius.zero,
        elevation: 0,
        border: false,
        specular: false,
        child: const SizedBox.expand(),
      ),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      shape: Border(bottom: BorderSide(color: palette.hairline, width: 0.5)),
      titleTextStyle: theme.textTheme.titleMedium?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3, // tighten as type grows
      ),
      bottom: bottom == null
          ? null
          : PreferredSize(preferredSize: Size.fromHeight(bottomHeight), child: bottom!),
    );
  }
}

/// Capsule glass button. Filled variant uses the accent on a solid layer so
/// label contrast never depends on what's behind the glass.
class GlassButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool filled;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final IconData? icon;

  const GlassButton({
    super.key,
    required this.child,
    this.onPressed,
    this.filled = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    this.color,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final radius = BorderRadius.circular(GlassRadius.capsule);

    final label = DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: filled ? theme.colorScheme.onPrimary : accent,
      ),
      child: IconTheme.merge(
        data: IconThemeData(size: 18, color: filled ? theme.colorScheme.onPrimary : accent),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon), const SizedBox(width: 7)],
          child,
        ]),
      ),
    );

    return PressableGlass(
      onTap: onPressed,
      enabled: onPressed != null,
      pressedScale: 0.96,
      borderRadius: radius,
      child: filled
          ? Container(
              padding: padding,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: radius,
                boxShadow: GlassPalette.of(context).shadow(elevation: 0.5),
              ),
              child: label,
            )
          : GlassSurface(
              weight: GlassWeight.thin,
              borderRadius: radius,
              padding: padding,
              elevation: 0.6,
              child: label,
            ),
    );
  }
}

/// Small glass pill used for status (method, code, content type).
class GlassChip extends StatelessWidget {
  final String label;
  final Color? color;
  final IconData? icon;
  final double fontSize;
  final EdgeInsetsGeometry padding;

  const GlassChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.fontSize = 10.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
  });

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final c = color ?? Theme.of(context).colorScheme.primary;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.withValues(alpha: palette.isDark ? 0.20 : 0.12),
        borderRadius: BorderRadius.circular(GlassRadius.xs * 0.7),
        border: Border.all(color: c.withValues(alpha: palette.isDark ? 0.34 : 0.22), width: 0.7),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: fontSize + 2, color: c),
          const SizedBox(width: 3),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3, // small text wants slightly positive tracking
            color: palette.isDark ? c.withValues(alpha: 0.95) : Color.lerp(c, Colors.black, 0.25),
          ),
        ),
      ]),
    );
  }
}

/// Grouped glass section — replaces the bordered `Card` used across settings.
/// Children are separated by inset hairlines, iOS-style.
class GlassSection extends StatelessWidget {
  final List<Widget> children;
  final String? header;
  final String? footer;
  final EdgeInsetsGeometry margin;

  const GlassSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin = const EdgeInsets.only(bottom: 14),
  });

  @override
  Widget build(BuildContext context) {
    final palette = GlassPalette.of(context);
    final theme = Theme.of(context);

    final separated = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i != children.length - 1) {
        separated.add(Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Divider(height: 0.5, thickness: 0.5, color: palette.hairline),
        ));
      }
    }

    return Padding(
      padding: margin,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 7),
            child: Text(
              header!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        GlassSurface(
          weight: GlassWeight.regular,
          borderRadius: BorderRadius.circular(GlassRadius.md),
          elevation: 0.7,
          child: Column(children: separated),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 7, 18, 0),
            child: Text(
              footer!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
      ]),
    );
  }
}

/// A row inside a [GlassSection] with press feedback and a chevron.
class GlassTile extends StatelessWidget {
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;
  final EdgeInsetsGeometry padding;

  const GlassTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final row = Padding(
      padding: padding,
      child: Row(children: [
        if (leading != null) ...[
          IconTheme.merge(
            data: IconThemeData(size: 20, color: theme.colorScheme.primary.withValues(alpha: 0.85)),
            child: leading!,
          ),
          const SizedBox(width: 13),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, letterSpacing: -0.2),
              child: title,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              DefaultTextStyle.merge(
                style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
                child: subtitle!,
              ),
            ],
          ]),
        ),
        if (trailing != null) trailing!,
        if (showChevron && onTap != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
          ),
      ]),
    );

    if (onTap == null) return row;
    return PressableGlass(
      onTap: onTap,
      pressedScale: 0.985,
      borderRadius: BorderRadius.circular(GlassRadius.sm),
      child: row,
    );
  }
}
