import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// The Little Love brand mark: a heart-shaped padlock with a keyhole. The same
/// mark as the home-screen app icon, so the welcome screen and the installed
/// icon read as one identity. It encodes the whole product: a heart (love)
/// that is also a lock (end-to-end private).
///
/// Rendered as a luminous symbol on the app canvas (not the pink app tile), so
/// it sits naturally on the dusk background. Body uses the "you" hue, the
/// shackle the "partner" hue, and the keyhole is punched in the canvas colour
/// so the whole thing themes with light/dark. Fades and scales in once on
/// mount for a quiet bit of life.
class HeartLock extends StatelessWidget {
  const HeartLock({super.key, this.size = 150});

  /// Width of the mark in logical pixels. Height is 1.25x; the glow extends
  /// beyond both.
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final box = size * 1.35;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 720),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
      child: SizedBox(
        width: box,
        height: box,
        child: Stack(
          alignment: Alignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    palette.accentUser.withValues(
                      alpha: palette.brightness == Brightness.dark
                          ? 0.36
                          : 0.16,
                    ),
                    palette.accentUser.withValues(alpha: 0),
                  ],
                  stops: const [0.0, 0.7],
                ),
              ),
              child: SizedBox(width: box, height: box),
            ),
            CustomPaint(
              size: Size(size, size * 1.25),
              painter: _HeartLockPainter(
                body: palette.accentUser,
                shackle: palette.accentPartner,
                keyhole: palette.bgCanvas,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeartLockPainter extends CustomPainter {
  _HeartLockPainter({
    required this.body,
    required this.shackle,
    required this.keyhole,
  });

  final Color body;
  final Color shackle;
  final Color keyhole;

  @override
  void paint(Canvas canvas, Size size) {
    // Author the mark in a fixed 120x150 space, then scale to fit.
    canvas.save();
    canvas.scale(size.width / 120, size.height / 150);

    // Shackle (drawn first so the heart body overlaps its feet, as on a lock).
    final shacklePath = Path()
      ..moveTo(44, 60)
      ..lineTo(44, 44)
      ..arcToPoint(
        const Offset(76, 44),
        radius: const Radius.circular(16),
        clockwise: true,
      )
      ..lineTo(76, 60);
    canvas.drawPath(
      shacklePath,
      Paint()
        ..color = shackle
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );

    // Heart body (the lock).
    final bodyPath = Path()
      ..moveTo(60, 70)
      ..cubicTo(60, 62, 53, 52, 40, 52)
      ..cubicTo(24, 52, 16, 64, 16, 78)
      ..cubicTo(16, 94, 34, 108, 60, 132)
      ..cubicTo(86, 108, 104, 94, 104, 78)
      ..cubicTo(104, 64, 96, 52, 80, 52)
      ..cubicTo(67, 52, 60, 62, 60, 70)
      ..close();
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = body
        ..isAntiAlias = true,
    );

    // Keyhole, punched in the canvas colour so it reads as a cutout.
    final hole = Paint()
      ..color = keyhole
      ..isAntiAlias = true;
    canvas.drawCircle(const Offset(60, 86), 6.5, hole);
    final slot = Path()
      ..moveTo(57, 90)
      ..lineTo(63, 90)
      ..lineTo(61.5, 102)
      ..lineTo(58.5, 102)
      ..close();
    canvas.drawPath(slot, hole);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeartLockPainter old) =>
      old.body != body || old.shackle != shackle || old.keyhole != keyhole;
}
