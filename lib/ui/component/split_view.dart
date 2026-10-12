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
  double _maxWidth = double.infinity;
  bool _hovering = false;
  bool _dragging = false;

  get _width1 => _ratio * _maxWidth;

  get _width2 => (1 - _ratio) * _maxWidth;

  @override
  void initState() {
    super.initState();
    _ratio = widget.ratio;
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
              width: _width1 - 5,
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
              onPanStart: (_) => setState(() => _dragging = true),
              onPanEnd: (DragEndDetails details) {
                setState(() => _dragging = false);
                widget.onRatioChanged?.call(_ratio);
              },
              onPanUpdate: (DragUpdateDetails details) {
                setState(() {
                  _ratio += details.delta.dx / _maxWidth;

                  // Rubber-band past the limits instead of stopping dead, so
                  // the boundary reads as resistance, not as a frozen UI.
                  if (_ratio > widget.maxRatio) {
                    final over = _ratio - widget.maxRatio;
                    _ratio = widget.maxRatio + rubberband(over, 1.0) * 0.25;
                  } else if (_ratio < widget.minRatio) {
                    final over = widget.minRatio - _ratio;
                    _ratio = widget.minRatio - rubberband(over, 1.0) * 0.25;
                  }
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
