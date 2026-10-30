import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/chat_separator.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';

/// WCAG contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('a separator label passes 4.5:1 at every point of every wallpaper, '
      'light and dark', () {
    for (final wallpaper in WallpaperGradient.values) {
      final p = AppPalette.of(wallpaper.brightness);
      for (final spot in [...wallpaper.colors, wallpaper.base]) {
        // With and without the doodle strokes drawn over that spot.
        for (final ground in [
          spot,
          Color.alphaBlend(wallpaper.doodleInk, spot),
        ]) {
          final behindText = Color.alphaBlend(
            p.bgSurface.withValues(alpha: ChatSeparator.scrimAlpha),
            ground,
          );
          expect(
            _contrast(p.separatorText, behindText),
            greaterThanOrEqualTo(4.5),
            reason: '${wallpaper.label} at $ground',
          );
        }
      }
    }
  });

  testWidgets('the separator is a faint scrim, not the old solid pill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: const Scaffold(body: ChatSeparator('Today 8:05 PM')),
      ),
    );
    final box = tester.widget<Container>(
      find.ancestor(
        of: find.text('Today 8:05 PM'),
        matching: find.byType(Container),
      ),
    );
    final fill = (box.decoration! as BoxDecoration).color!;
    expect(fill.a, lessThanOrEqualTo(0.5));
  });
}
