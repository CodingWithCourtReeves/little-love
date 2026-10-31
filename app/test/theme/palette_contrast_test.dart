import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/app_palette.dart';

/// WCAG contrast ratio between two colors, using Flutter's own relative
/// luminance (`computeLuminance` implements the WCAG formula).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // Guards future token edits so on-device tuning can't silently hurt
  // legibility. Two WCAG thresholds: body text needs 4.5:1; secondary text
  // (muted) and accent-UI/large text need 3:1.
  const aaBody = 4.5;
  const aaLarge = 3.0;

  for (final entry in {
    'light': AppPalette.light,
    'dark': AppPalette.dark,
  }.entries) {
    final name = entry.key;
    final p = entry.value;

    test('$name: textPrimary on bgSurface clears body AA', () {
      expect(
        _contrast(p.textPrimary, p.bgSurface),
        greaterThanOrEqualTo(aaBody),
      );
    });

    test('$name: textMuted on bgSurface clears large/secondary AA', () {
      expect(
        _contrast(p.textMuted, p.bgSurface),
        greaterThanOrEqualTo(aaLarge),
      );
    });

    test('$name: accentUser on bgSurface clears accent-UI AA', () {
      expect(
        _contrast(p.accentUser, p.bgSurface),
        greaterThanOrEqualTo(aaLarge),
      );
    });

    test('$name: bubbleUserText on bubbleUserBg clears body AA', () {
      expect(
        _contrast(p.bubbleUserText, p.bubbleUserBg),
        greaterThanOrEqualTo(aaBody),
      );
    });

    test('$name: textPrimary on bubblePartnerBg clears body AA', () {
      expect(
        _contrast(p.textPrimary, p.bubblePartnerBg),
        greaterThanOrEqualTo(aaBody),
      );
    });

    // In-chat search (#96) marks matches inside bubbles: a translucent tint on
    // the others, a solid mark with its own text color on the current one.
    test('$name: bubble text on the search tint clears body AA, both '
        'bubbles', () {
      expect(
        _contrast(
          p.bubbleUserText,
          Color.alphaBlend(p.searchMatch, p.bubbleUserBg),
        ),
        greaterThanOrEqualTo(aaBody),
      );
      expect(
        _contrast(
          p.textPrimary,
          Color.alphaBlend(p.searchMatch, p.bubblePartnerBg),
        ),
        greaterThanOrEqualTo(aaBody),
      );
    });

    test('$name: the current search match clears body AA', () {
      expect(
        _contrast(p.searchMatchCurrentText, p.searchMatchCurrent),
        greaterThanOrEqualTo(aaBody),
      );
    });

    test('$name: channel swatch ink clears 4.5:1 on its tint', () {
      expect(p.channelSwatches, hasLength(6));
      for (final sw in p.channelSwatches) {
        expect(_contrast(sw.ink, sw.tint), greaterThanOrEqualTo(aaBody));
      }
    });
  }
}
