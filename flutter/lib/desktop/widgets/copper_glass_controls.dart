import 'package:flutter/material.dart';

/// A small glass-like surface for control chrome. Layered translucent gradients
/// provide the frost without a backdrop filter reading the live remote video.
/// Pointer movement repaints only this background; there is no animation ticker.
class CopperGlassControls extends StatefulWidget {
  static const accent = Color(0xFFB76742);
  static const accentHover = Color(0xFFC97B52);
  static const foreground = Color(0xFFF8EDE6);
  static const card = Color(0xFF2D2525);
  static const border = Color(0x42FFFFFF);

  final Widget child;
  final BorderRadius borderRadius;
  final bool interactive;

  const CopperGlassControls({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.interactive = true,
  });

  @override
  State<CopperGlassControls> createState() => _CopperGlassControlsState();
}

class _CopperGlassControlsState extends State<CopperGlassControls> {
  final _pointer = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _pointer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final followPointer = widget.interactive &&
        TickerMode.of(context) &&
        !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false);
    if (!followPointer) _pointer.value = null;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        boxShadow: const [
          BoxShadow(
              color: Color(0x30000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xF060443A), Color(0xF2332B2A), Color(0xF0272328)],
            ),
          ),
          position: DecorationPosition.background,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: _CopperLight(_pointer)),
                  ),
                ),
              ),
              RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    border: Border.all(color: CopperGlassControls.border),
                  ),
                  // Preserve the former toolbar border's 1px layout inset.
                  child: Padding(
                      padding: const EdgeInsets.all(1), child: widget.child),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return MouseRegion(
      // Keep the same tree when dragging or reducing motion so the existing
      // controls retain their gesture/focus state. Only hover callbacks stop.
      onHover: followPointer
          ? (event) => _pointer.value = event.localPosition
          : null,
      onExit: followPointer ? (_) => _pointer.value = null : null,
      child: surface,
    );
  }
}

class _CopperLight extends CustomPainter {
  final ValueNotifier<Offset?> pointer;
  _CopperLight(this.pointer) : super(repaint: pointer);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    // Fixed soft highlights create a frosted-looking layered dark card even
    // when reduced motion is enabled. Every pixel is clipped to this surface.
    canvas.drawRect(
        bounds,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.7, -1),
            radius: 1.4,
            colors: [Color(0x458F675B), Color(0x008F675B)],
          ).createShader(bounds));
    final position = pointer.value;
    if (position != null && !size.isEmpty) {
      final glow = Rect.fromCircle(center: position, radius: 90);
      canvas.drawRect(
          bounds,
          Paint()
            ..shader = const RadialGradient(
              colors: [Color(0x50FFC29B), Color(0x00FFC29B)],
            ).createShader(glow));
    }
  }

  @override
  bool shouldRepaint(covariant _CopperLight oldDelegate) =>
      oldDelegate.pointer != pointer;
}
