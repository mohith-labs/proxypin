import 'package:flutter/material.dart';

import 'liquid/liquid.dart';

class VerticalSplitView extends StatefulWidget {
  final Widget left;
  final Widget right;
  final double ratio;
  final double minRatio;
  final double maxRatio;
  final Function(double ratio)? onRatioChanged;

  const VerticalSplitView(
      {super.key,
      required this.left,
      required this.right,
      this.ratio = 0.5,
      this.minRatio = 0,
      this.maxRatio = 1,
      this.onRatioChanged})
      : assert(ratio >= 0 && ratio <= 1);

  @override
  State<VerticalSplitView> createState() => _VerticalSplitViewState();
}

class _VerticalSplitViewState extends State<VerticalSplitView> {
  final _dividerWidth = 10.0;

  //from 0-1
  late double _ratio;

  /// The undamped drag position. [_ratio] is derived from this, never fed
  /// back into it — otherwise each frame would rubber-band an already
  /// rubber-banded value and the ratio would creep past its bounds.
  late double _rawRatio;

  double _maxWidth = double.infinity;
  bool _hovering = false;
  bool _dragging = false;

  // Never allow a negative width: the Row below subtracts the divider gap,
  // and a negative constraint is a hard layout assertion.
  double get _width1 => (_ratio * _maxWidth - 5).clamp(0.0, double.infinity);

  double get _width2 => ((1 - _ratio) * _maxWidth - 5).clamp(0.0, double.infinity);

  @override
  void initState() {
    super.initState();
    _ratio = widget.ratio;
    _rawRatio = widget.ratio;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, BoxConstraints constraints) {
      if (_maxWidth != constraints.maxWidth) {
        _maxWidth = constraints.maxWidth - _dividerWidth;
      }

      return SizedBox(
        width: constraints.maxWidth,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: _width1,
              child: widget.left,
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  onEnter: (_) => setState(() => _hovering = true),
                  onExit: (_) => setState(() => _hovering = false),
                  child: SizedBox(
                    width: _dividerWidth,
                    height: double.infinity,
                    child: Center(
                      // Grab handle brightens on hover/drag — the affordance
                      // responds before the drag even starts.
                      child: AnimatedContainer(
                        duration: GlassDuration.fast,
                        curve: GlassCurves.standard,
                        width: (_hovering || _dragging) ? 4 : 1.5,
                        height: (_hovering || _dragging) ? 44 : double.infinity,
                        decoration: BoxDecoration(
                          color: (_hovering || _dragging)
                              ? Theme.of(context).colorScheme.primary.withValues(alpha: _dragging ? 0.85 : 0.55)
                              : GlassPalette.of(context).hairline,
                          borderRadius: BorderRadius.circular(GlassRadius.capsule),
                        ),
                      ),
                    ),
                  )),
              onPanStart: (_) => setState(() {
                _dragging = true;
                // Re-sync: the raw position starts from wherever we settled.
                _rawRatio = _ratio;
              }),
              onPanEnd: (DragEndDetails details) {
                setState(() {
                  _dragging = false;
                  // Release snaps back inside the limits, the way an iOS
                  // overscroll returns once you let go.
                  _rawRatio = _rawRatio.clamp(widget.minRatio, widget.maxRatio);
                  _ratio = _rawRatio;
                });
                widget.onRatioChanged?.call(_ratio);
              },
              onPanUpdate: (DragUpdateDetails details) {
                setState(() {
                  // Accumulate on the RAW value so damping never compounds.
                  _rawRatio += details.delta.dx / _maxWidth;

                  // Rubber-band past the limits instead of stopping dead, so
                  // the boundary reads as resistance, not as a frozen UI.
                  if (_rawRatio > widget.maxRatio) {
                    final over = _rawRatio - widget.maxRatio;
                    _ratio = widget.maxRatio + rubberband(over, 1.0) * 0.25;
                  } else if (_rawRatio < widget.minRatio) {
                    final over = widget.minRatio - _rawRatio;
                    _ratio = widget.minRatio - rubberband(over, 1.0) * 0.25;
                  } else {
                    _ratio = _rawRatio;
                  }

                  // Hard safety clamp: _width1/_width2 must stay non-negative
                  // even if a gesture delivers an extreme delta.
                  _ratio = _ratio.clamp(0.02, 0.98);
                });
              },
            ),
            SizedBox(
              width: _width2,
              child: widget.right,
            ),
          ],
        ),
      );
    });
  }
}
