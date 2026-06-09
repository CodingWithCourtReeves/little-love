import 'package:flutter/material.dart';

/// Hearth, light variant. Values lifted verbatim from
/// design spec §11.4 and mocks/palette-gallery.html.
class HearthColors {
  static const bgCanvas       = Color(0xFFFBEEDD);
  static const bgSurface      = Color(0xFFF5E2C9);
  static const bgSurfaceAlt   = Color(0xFFEFD6B3);
  static const textPrimary    = Color(0xFF2C1E16);
  static const textMuted      = Color(0xFF8A6E58);
  static const accentUser     = Color(0xFFB23F2E);
  static const accentPartner  = Color(0xFFC97E5A);
  static const accentFamiliar = Color(0xFF9A6B1E);
  static const borderSoft     = Color(0xFFE3CBA6);
  static const ruleStrong     = Color(0xFF9A6B1E);

  // Bubble shades used by the conversation view.
  static const bubbleUserBg     = Color(0xFFF0C7BC);
  static const bubbleUserText   = Color(0xFF3F1A12);
  static const bubblePartnerBg  = Color(0xFFFFFAF0);
}

/// Builds a Material ThemeData using Hearth colors. Phase 1.5
/// will replace this with a token-driven ThemeExtension; Day-1
/// uses the simplest binding that produces the right look.
ThemeData buildHearthTheme() {
  const base = ColorScheme.light(
    primary: HearthColors.accentUser,
    onPrimary: Colors.white,
    secondary: HearthColors.accentFamiliar,
    surface: HearthColors.bgSurface,
    onSurface: HearthColors.textPrimary,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    scaffoldBackgroundColor: HearthColors.bgCanvas,
    fontFamily: 'Inter',
  );
}
