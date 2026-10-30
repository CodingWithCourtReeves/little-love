import 'dart:typed_data';

import 'package:flutter/rendering.dart';

import 'bubble_run.dart';

/// Paints a chat bubble: a rounded rectangle with, on the last bubble of a run
/// ([tail]), a small tail curling out of the bottom corner on the sender's
/// side (right for my messages, left for the partner's), like iMessage.
///
/// The tail lives in a [tailGutter]-wide strip on the sender's side whether or
/// not it is drawn, so every bubble in a run shares the same outer edge and
/// the run reads as one straight column. Corner radii are per corner
/// ([radius], in screen terms), so the corners facing the neighbouring bubbles
/// of a run can soften to [innerRadius] (#84).
class BubbleBackground extends CustomPainter {
  const BubbleBackground({
    required this.color,
    required this.border,
    required this.mine,
    required this.tail,
    required this.radius,
  });

  final Color color;

  /// 1px outline, or null for none.
  final Color? border;
  final bool mine;

  /// Whether to draw the tail. When false the tail-side bottom corner is
  /// rounded by [radius] instead.
  final bool tail;

  /// Per-corner radii in screen terms. The tail-side bottom radius only
  /// applies when there's no [tail].
  final BorderRadius radius;

  /// The 15px corner of a bubble's outer edge (and every corner of a lone one).
  static const double outerRadius = 15;

  /// The softer corner facing the next or previous bubble of the same run.
  static const double innerRadius = 6;

  /// Width of the strip on the sender's side the tail occupies.
  static const double tailGutter = 5;

  /// The corners for a bubble at [position] in its run: the outer edge keeps
  /// [outerRadius]; on the sender's side, the top corner softens when a bubble
  /// sits above in the same run, the bottom one when a bubble follows.
  static BorderRadius cornersFor(RunPosition position, {required bool mine}) {
    const outer = Radius.circular(outerRadius);
    const inner = Radius.circular(innerRadius);
    final top = position.startsRun ? outer : inner;
    final bottom = position.endsRun ? outer : inner;
    return mine
        ? BorderRadius.only(
            topLeft: outer,
            bottomLeft: outer,
            topRight: top,
            bottomRight: bottom,
          )
        : BorderRadius.only(
            topLeft: top,
            bottomLeft: bottom,
            topRight: outer,
            bottomRight: outer,
          );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true
        ..style = PaintingStyle.fill,
    );
    final stroke = border;
    if (stroke == null) return;
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// The bubble outline. Built for my side (tail at the bottom-right) and
  /// mirrored for the partner's, with the radii swapped to match.
  Path _path(Size size) {
    final w = size.width;
    // Radii in "my side" terms: the tail side is the right.
    final r = mine
        ? radius
        : BorderRadius.only(
            topLeft: radius.topRight,
            topRight: radius.topLeft,
            bottomLeft: radius.bottomRight,
            bottomRight: radius.bottomLeft,
          );
    final path = tail ? _tailed(size, r) : _plain(size, r);
    if (mine) return path;
    // x -> w - x (column-major 4x4).
    return path.transform(
      Float64List.fromList([-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, w, 0, 0, 1]),
    );
  }

  /// The canonical iMessage bubble path: rounded corners on three sides and a
  /// curled tail at the bottom-right. The tail isn't a flat flare: the edge
  /// runs down past the corner, pokes out to the box edge, then *hooks back
  /// inward* with a little curl (the control points dip just past the bottom
  /// edge). Tail coordinates are the fixed pixel landmarks from Apple's shape
  /// (it spans ~20px), so it reads identically at any bubble size.
  Path _tailed(Size size, BorderRadius r) {
    final w = size.width;
    final h = size.height;
    final edge = w - tailGutter;
    final tl = _fit(r.topLeft.x, size);
    final tr = _fit(r.topRight.x, size);
    final bl = _fit(r.bottomLeft.x, size);
    final path = Path()
      ..moveTo(w - 20, h)
      ..lineTo(bl, h);
    _corner(path, Offset(0, h), Offset(bl, h), Offset(0, h - bl));
    path.lineTo(0, tl);
    _corner(path, Offset.zero, Offset(0, tl), Offset(tl, 0));
    path.lineTo(edge - tr, 0);
    _corner(path, Offset(edge, 0), Offset(edge - tr, 0), Offset(edge, tr));
    return path
      ..lineTo(edge, h - 10) // right edge runs down past the corner
      ..cubicTo(edge, h - 1, w, h, w, h) // poke out to the tail tip
      ..cubicTo(w - 4, h + 1, w - 8, h - 1, w - 12, h - 4) // curl back in
      ..cubicTo(w - 15, h - 1, w - 18, h, w - 20, h) // rejoin bottom edge
      ..close();
  }

  /// A tailless bubble: a rounded rectangle inside the same body as
  /// [_tailed], leaving the tail gutter empty.
  Path _plain(Size size, BorderRadius r) {
    final h = size.height;
    final edge = size.width - tailGutter;
    final tl = _fit(r.topLeft.x, size);
    final tr = _fit(r.topRight.x, size);
    final bl = _fit(r.bottomLeft.x, size);
    final br = _fit(r.bottomRight.x, size);
    final path = Path()
      ..moveTo(edge - br, h)
      ..lineTo(bl, h);
    _corner(path, Offset(0, h), Offset(bl, h), Offset(0, h - bl));
    path.lineTo(0, tl);
    _corner(path, Offset.zero, Offset(0, tl), Offset(tl, 0));
    path.lineTo(edge - tr, 0);
    _corner(path, Offset(edge, 0), Offset(edge - tr, 0), Offset(edge, tr));
    path.lineTo(edge, h - br);
    _corner(path, Offset(edge, h), Offset(edge, h - br), Offset(edge - br, h));
    return path..close();
  }

  /// A radius no larger than half the bubble's height, so a short bubble's
  /// corners can't overlap.
  static double _fit(double r, Size size) {
    final cap = size.height / 2;
    return r < cap ? r : cap;
  }

  /// Rounds the corner at [vertex], from [from] (where the path is) to [to].
  /// The control points sit 8/15 of the way from the vertex toward each end,
  /// the proportion of the original 15px iMessage corner.
  static void _corner(Path path, Offset vertex, Offset from, Offset to) {
    const k = 8 / 15;
    final c1 = vertex + (from - vertex) * k;
    final c2 = vertex + (to - vertex) * k;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, to.dx, to.dy);
  }

  @override
  bool shouldRepaint(BubbleBackground old) =>
      old.color != color ||
      old.border != border ||
      old.mine != mine ||
      old.tail != tail ||
      old.radius != radius;
}
