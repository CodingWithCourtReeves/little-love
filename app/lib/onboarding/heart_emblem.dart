import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// The Little Love mark: one heart split down the middle, the left half in
/// [AppPalette.accentUser] (the "you" hue) and the right half in
/// [AppPalette.accentSage] (the "them" hue). Two of you, one heart. A soft
/// radial glow sits behind it. All colours derive from the active palette, so
/// it reads warm in both the light ("the hour the lamps come on") and dark
/// ("Deep Dusk") themes.
class HeartEmblem extends StatelessWidget {
  const HeartEmblem({super.key, this.size = 96});

  /// Width of the heart in logical pixels. The glow extends beyond this.
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final box = size * 1.6;
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft glow, tinted from the "you" hue so it reads warm in both
          // themes (a gentle wash on light, a true glow on dark).
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  palette.accentUser.withValues(
                    alpha: palette.brightness == Brightness.dark ? 0.38 : 0.18,
                  ),
                  palette.accentUser.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.72],
              ),
            ),
            child: SizedBox(width: box, height: box),
          ),
          CustomPaint(
            size: Size(size, size * 0.92),
            painter: _HeartPainter(
              left: palette.accentUser,
              right: palette.accentSage,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeartPainter extends CustomPainter {
  _HeartPainter({required this.left, required this.right});

  final Color left;
  final Color right;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0.50 * w, 0.30 * h)
      ..cubicTo(0.42 * w, 0.12 * h, 0.10 * w, 0.12 * h, 0.06 * w, 0.36 * h)
      ..cubicTo(0.02 * w, 0.55 * h, 0.30 * w, 0.72 * h, 0.50 * w, 0.92 * h)
      ..cubicTo(0.70 * w, 0.72 * h, 0.98 * w, 0.55 * h, 0.94 * w, 0.36 * h)
      ..cubicTo(0.90 * w, 0.12 * h, 0.58 * w, 0.12 * h, 0.50 * w, 0.30 * h)
      ..close();

    // Paint the whole heart in the right hue, then clip to the left half and
    // overpaint the left hue. The overlap guarantees a seamless centre split
    // (no anti-aliased hairline gap).
    canvas.drawPath(
      path,
      Paint()
        ..color = right
        ..isAntiAlias = true,
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w / 2, h));
    canvas.drawPath(
      path,
      Paint()
        ..color = left
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeartPainter old) =>
      old.left != left || old.right != right;
}
