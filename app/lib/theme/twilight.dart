import 'package:flutter/material.dart';

/// Twilight, light variant. The hour after the lamps come on - aubergine
/// canvas, pale rose, sage in the corner of the eye. Values lifted verbatim
/// from design spec §11.4 and mocks/palette-gallery.html.
class TwilightColors {
  static const bgCanvas = Color(0xFFF4EBEC);
  static const bgSurface = Color(0xFFEBDFE2);
  static const bgSurfaceAlt = Color(0xFFE2D3D8);
  static const textPrimary = Color(0xFF2A1F2A);
  static const textMuted = Color(0xFF7C6C78);
  static const accentUser = Color(0xFFA04A6A);
  static const accentPartner = Color(0xFF9C7E94);
  static const accentFamiliar = Color(0xFF4F7A5E);
  static const borderSoft = Color(0xFFD9C7CD);
  static const ruleStrong = Color(0xFF4F7A5E);

  // Bubble shades used by the conversation view.
  static const bubbleUserBg = Color(0xFFE8C8D2);
  static const bubbleUserText = Color(0xFF3A1424);
  static const bubblePartnerBg = Color(0xFFFFFAFB);

  /// Sage tint for familiar (bot) message bubbles — distinguishes AI
  /// participants from the partner's white bubbles. Values mirror the v0.4
  /// mock (mocks/v0.4/channel-with-familiar.html).
  static const Color bubbleFamiliarBg = Color(0xFFEFEDDF);
  static const Color bubbleFamiliarBorder = Color(0xFFDFDCC4);
}

/// Builds a Material ThemeData using Twilight colors. Phase 1.5
/// will replace this with a token-driven ThemeExtension; Day-1
/// uses the simplest binding that produces the right look.
ThemeData buildTwilightTheme() {
  const base = ColorScheme.light(
    primary: TwilightColors.accentUser,
    onPrimary: Colors.white,
    secondary: TwilightColors.accentFamiliar,
    surface: TwilightColors.bgSurface,
    onSurface: TwilightColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: TwilightColors.bgCanvas,
    fontFamily: 'Inter',
  );
}

/// Editorial type scale. One typeface (Inter), multiple voices.
/// Use these instead of raw Text(style: ...) so every screen rhymes.
class TwilightType {
  static const _f = 'Inter';

  /// Display headline — auth screens, empty states. Tight, weighty.
  static const display = TextStyle(
    fontFamily: _f,
    fontSize: 32,
    height: 1.12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.7,
    color: TwilightColors.textPrimary,
  );

  /// Mid headline — section titles within a screen.
  static const title = TextStyle(
    fontFamily: _f,
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.25,
    color: TwilightColors.textPrimary,
  );

  /// Body — composer text, bubble text, prose.
  static const body = TextStyle(
    fontFamily: _f,
    fontSize: 15,
    height: 1.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    color: TwilightColors.textPrimary,
  );

  /// Annotation — sidebar section headers, step markers, kbd hints.
  /// Wide tracking so it reads like a footer caption.
  static const annotation = TextStyle(
    fontFamily: _f,
    fontSize: 11,
    height: 1.0,
    fontWeight: FontWeight.w500,
    letterSpacing: 2.4,
    color: TwilightColors.textMuted,
  );

  /// Muted body — sub-copy under headlines.
  static const lede = TextStyle(
    fontFamily: _f,
    fontSize: 14,
    height: 1.6,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    color: TwilightColors.textMuted,
  );
}
