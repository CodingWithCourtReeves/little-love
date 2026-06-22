import 'dart:math' as math;
import 'package:flutter/material.dart';

/// One placement of a doodle within the 230x230 cell.
class _Doodle {
  const _Doodle(
    this.draw,
    this.x,
    this.y,
    this.scale,
    this.rotation, {
    this.fill = false,
  });
  final void Function(Canvas, Paint) draw;
  final double x, y, scale, rotation;
  final bool fill;
}

const _cell = 230.0;

/// Tiles the Love-Doodles cell across [size], inked with [ink].
void paintDoodleField(Canvas canvas, Size size, Color ink) {
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = ink;
  final fill = Paint()
    ..style = PaintingStyle.fill
    ..color = ink;

  for (var oy = 0.0; oy < size.height; oy += _cell) {
    for (var ox = 0.0; ox < size.width; ox += _cell) {
      canvas.save();
      canvas.translate(ox, oy);
      for (final d in _doodles) {
        canvas.save();
        canvas.translate(d.x, d.y);
        canvas.rotate(d.rotation * math.pi / 180);
        canvas.scale(d.scale);
        d.draw(canvas, d.fill ? fill : stroke);
        canvas.restore();
      }
      canvas.restore();
    }
  }
}

// --- doodle primitives (drawn around a ~24x24 local origin) ---

void _heart(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(12, 20)
    ..cubicTo(5, 14, 3, 9.5, 6.2, 6.8)
    ..cubicTo(8.4, 5, 11, 6, 12, 8.2)
    ..cubicTo(13, 6, 15.6, 5, 17.8, 6.8)
    ..cubicTo(21, 9.5, 19, 14, 12, 20)
    ..close();
  c.drawPath(path, p);
}

void _star(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(12, 3)
    ..cubicTo(12.6, 8, 13, 9.4, 21, 12)
    ..cubicTo(13, 14.6, 12.6, 16, 12, 21)
    ..cubicTo(11.4, 16, 11, 14.6, 3, 12)
    ..cubicTo(11, 9.4, 11.4, 8, 12, 3)
    ..close();
  c.drawPath(path, p);
}

void _chat(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(5, 6)
    ..lineTo(17, 6)
    ..arcToPoint(const Offset(19, 8), radius: const Radius.circular(2))
    ..lineTo(19, 12)
    ..arcToPoint(const Offset(17, 14), radius: const Radius.circular(2))
    ..lineTo(11, 14)
    ..lineTo(7, 17)
    ..lineTo(7, 14)
    ..lineTo(5, 14)
    ..arcToPoint(const Offset(3, 12), radius: const Radius.circular(2))
    ..lineTo(3, 8)
    ..arcToPoint(const Offset(5, 6), radius: const Radius.circular(2))
    ..close();
  c.drawPath(path, p);
}

void _envelope(Canvas c, Paint p) {
  c.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(4, 7, 16, 11),
      const Radius.circular(1.5),
    ),
    p,
  );
  c.drawPath(
    Path()
      ..moveTo(4.5, 8)
      ..lineTo(12, 13.5)
      ..lineTo(19.5, 8),
    p,
  );
}

void _ring(Canvas c, Paint p) {
  c.drawCircle(const Offset(12, 15), 5, p);
  c.drawPath(
    Path()
      ..moveTo(9, 11)
      ..lineTo(12, 7)
      ..lineTo(15, 11),
    p,
  );
}

void _plane(Canvas c, Paint p) {
  c.drawPath(
    Path()
      ..moveTo(3, 12)
      ..lineTo(21, 4)
      ..lineTo(14, 20)
      ..lineTo(11, 13)
      ..close(),
    p,
  );
}

void _cup(Canvas c, Paint p) {
  c.drawPath(
    Path()
      ..moveTo(5, 10)
      ..lineTo(15, 10)
      ..lineTo(15, 14)
      ..arcToPoint(
        const Offset(5, 14),
        radius: const Radius.circular(5),
        clockwise: false,
      )
      ..close(),
    p,
  );
  c.drawPath(
    Path()
      ..moveTo(15, 11)
      ..arcToPoint(const Offset(15, 15), radius: const Radius.circular(2.5)),
    p,
  );
}

void _spark(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 5), const Offset(12, 11), p);
  c.drawLine(const Offset(12, 13), const Offset(12, 19), p);
  c.drawLine(const Offset(5, 12), const Offset(11, 12), p);
  c.drawLine(const Offset(13, 12), const Offset(19, 12), p);
}

/// 20 scattered placements (ported from the approved mockup tile). Mix of
/// filled hearts/stars and outline objects, rotated so the grid stops reading.
const List<_Doodle> _doodles = [
  _Doodle(_heart, 0, 0, 1.05, -12, fill: true),
  _Doodle(_chat, 60, 8, 1.0, 8),
  _Doodle(_envelope, 120, 2, 1.05, -6),
  _Doodle(_ring, 182, 12, 1.0, 14),
  _Doodle(_spark, 36, 40, 0.9, 0),
  _Doodle(_heart, 92, 54, 0.9, 18),
  _Doodle(_plane, 150, 48, 1.05, -18),
  _Doodle(_heart, 200, 64, 0.85, 10, fill: true),
  _Doodle(_cup, 6, 86, 1.05, 6),
  _Doodle(_star, 64, 100, 0.85, -10, fill: true),
  _Doodle(_envelope, 116, 92, 1.0, 16),
  _Doodle(_heart, 176, 104, 1.0, -14),
  _Doodle(_chat, 20, 138, 1.0, -8),
  _Doodle(_heart, 78, 150, 0.9, 20, fill: true),
  _Doodle(_ring, 132, 146, 0.9, -16),
  _Doodle(_spark, 190, 156, 0.9, 0),
  _Doodle(_plane, 8, 186, 1.05, 12),
  _Doodle(_heart, 66, 196, 0.9, -18),
  _Doodle(_cup, 118, 190, 1.0, 10),
  _Doodle(_star, 178, 198, 0.85, -10, fill: true),
];
