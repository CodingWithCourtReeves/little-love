import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/bubble_background.dart';
import 'package:littlelove/conversation/bubble_run.dart';

/// Paints [painter] at [size] and returns the alpha of each probe point (0 =
/// outside the bubble, 255 = inside).
Future<Map<Offset, int>> _probe(
  BubbleBackground painter,
  Size size,
  List<Offset> points,
) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  // Room for the tail curl, which dips a pixel below the box.
  final image = await recorder.endRecording().toImage(
    size.width.ceil(),
    size.height.ceil() + 2,
  );
  final bytes = (await image.toByteData())!;
  int alphaAt(Offset p) =>
      bytes.getUint8(((p.dy.floor() * image.width) + p.dx.floor()) * 4 + 3);
  return {for (final p in points) p: alphaAt(p)};
}

BubbleBackground _bubble({required bool mine, required RunPosition position}) =>
    BubbleBackground(
      color: const Color(0xFFFF0000),
      border: null,
      mine: mine,
      tail: position.hasTail,
      radius: BubbleBackground.cornersFor(position, mine: mine),
    );

void main() {
  const size = Size(120, 40);
  const g = BubbleBackground.tailGutter;

  testWidgets('a tailed bubble pokes into the gutter on the sender\'s side; '
      'the partner\'s is its mirror', (tester) async {
    await tester.runAsync(() async {
      // Bottom-right tail tip for mine, bottom-left for the partner's.
      final mine = await _probe(
        _bubble(mine: true, position: RunPosition.single),
        size,
        [const Offset(116.5, 38), const Offset(3.5, 38)],
      );
      expect(mine[const Offset(116.5, 38)], greaterThan(0));
      expect(mine[const Offset(3.5, 38)], 0, reason: 'rounded, no tail');

      final theirs = await _probe(
        _bubble(mine: false, position: RunPosition.single),
        size,
        [const Offset(3.5, 38), const Offset(116.5, 38)],
      );
      expect(theirs[const Offset(3.5, 38)], greaterThan(0));
      expect(theirs[const Offset(116.5, 38)], 0, reason: 'rounded, no tail');
    });
  });

  testWidgets('tailless and tailed bubbles share one outer edge, leaving the '
      'gutter empty without a tail', (tester) async {
    await tester.runAsync(() async {
      for (final mine in [true, false]) {
        // Mid-height, just inside and just outside the body's outer edge.
        final inside = Offset(mine ? size.width - g - 1.5 : g + 1.5, 20);
        final gutter = Offset(mine ? size.width - 1.5 : 1.5, 20);
        for (final position in RunPosition.values) {
          final a = await _probe(
            _bubble(mine: mine, position: position),
            size,
            [inside, gutter],
          );
          final label = 'mine: $mine, $position';
          expect(a[inside], 255, reason: label);
          expect(a[gutter], 0, reason: label);
        }
      }
    });
  });

  testWidgets('the soft inner corner is tighter than the outer one', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A middle bubble of mine: top-left is the 15px outer corner, top-right
      // (facing the bubble above) the 6px inner one. A point 3px in from each
      // top corner is outside the 15px curve but inside the 6px one.
      final a = await _probe(
        _bubble(mine: true, position: RunPosition.middle),
        size,
        [const Offset(3, 3), Offset(size.width - g - 3, 3)],
      );
      expect(a[const Offset(3, 3)], 0);
      expect(a[Offset(size.width - g - 3, 3)], 255);
    });
  });

  testWidgets('a bubble shorter than two corners still paints a closed shape '
      '(radii capped at half its height)', (tester) async {
    await tester.runAsync(() async {
      const short = Size(120, 20);
      for (final mine in [true, false]) {
        final a = await _probe(
          _bubble(mine: mine, position: RunPosition.first),
          short,
          [const Offset(60, 10), const Offset(60, 1), const Offset(60, 19)],
        );
        // Filled straight across the middle, top and bottom edges intact.
        expect(a.values, everyElement(255), reason: 'mine: $mine');
      }
    });
  });
}
