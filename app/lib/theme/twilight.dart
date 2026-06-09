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
