import 'package:flutter/material.dart';

/// The product palette, delivered at runtime through [ThemeData] so the whole
/// app (every screen, sheet, dialog, the Material defaults) recolors when the
/// wallpaper's brightness changes. One warm-dusk identity in two brightnesses:
/// the light variant is "the hour the lamps come on"; the dark variant is the
/// Deep Dusk wallpaper world, so the dark theme and the dark wallpapers are
/// literally the same night.
///
/// Field names mirror the historical `TwilightColors` tokens 1:1 so call sites
/// read `context.palette.x` where they used to read `TwilightColors.x`.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgSurfaceAlt,
    required this.textPrimary,
    required this.textMuted,
    required this.accentUser,
    required this.accentUserSoft,
    required this.accentPartner,
    required this.accentSage,
    required this.borderSoft,
    required this.ruleStrong,
    required this.warningTone,
    required this.bubbleUserBg,
    required this.bubbleUserText,
    required this.bubblePartnerBg,
  });

  final Brightness brightness;
  final Color bgCanvas;
  final Color bgSurface;
  final Color bgSurfaceAlt;
  final Color textPrimary;
  final Color textMuted;
  final Color accentUser;
  final Color accentUserSoft;
  final Color accentPartner;
  final Color accentSage;
  final Color borderSoft;
  final Color ruleStrong;
  final Color warningTone;
  final Color bubbleUserBg;
  final Color bubbleUserText;
  final Color bubblePartnerBg;

  /// "The hour the lamps come on" — pale rose / aubergine neutrals. Values are
  /// the original Twilight light palette, unchanged.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    bgCanvas: Color(0xFFF4EBEC),
    bgSurface: Color(0xFFEBDFE2),
    bgSurfaceAlt: Color(0xFFE2D3D8),
    textPrimary: Color(0xFF2A1F2A),
    textMuted: Color(0xFF7C6C78),
    accentUser: Color(0xFFA04A6A),
    accentUserSoft: Color(0xFFC98EA3),
    accentPartner: Color(0xFF9C7E94),
    accentSage: Color(0xFF4F7A5E),
    borderSoft: Color(0xFFD9C7CD),
    ruleStrong: Color(0xFF4F7A5E),
    warningTone: Color(0xFFB85C5C),
    bubbleUserBg: Color(0xFFE8C8D2),
    bubbleUserText: Color(0xFF3A1424),
    bubblePartnerBg: Color(0xFFFFFAFB),
  );

  /// "Deep dusk" — the Deep Dusk wallpaper world as the app canvas. The rose
  /// accent is lifted and desaturated so it reads cleanly on dark without
  /// vibrating; the you/partner two-hue distinction is preserved.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    bgCanvas: Color(0xFF181019),
    bgSurface: Color(0xFF241A28),
    bgSurfaceAlt: Color(0xFF322438),
    textPrimary: Color(0xFFF4EBEC),
    textMuted: Color(0xFFB7A6B1),
    accentUser: Color(0xFFC98EA3),
    accentUserSoft: Color(0xFFE0B6C6),
    accentPartner: Color(0xFFB6A0B2),
    accentSage: Color(0xFF8FB89A),
    borderSoft: Color(0xFF3D2E42),
    ruleStrong: Color(0xFF8FB89A),
    warningTone: Color(0xFFE58A8A),
    bubbleUserBg: Color(0xFF5E2C49),
    bubbleUserText: Color(0xFFF6E5EC),
    bubblePartnerBg: Color(0xFF2E2233),
  );

  /// The palette for a given brightness — the seam the wallpaper drives.
  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  AppPalette copyWith({
    Brightness? brightness,
    Color? bgCanvas,
    Color? bgSurface,
    Color? bgSurfaceAlt,
    Color? textPrimary,
    Color? textMuted,
    Color? accentUser,
    Color? accentUserSoft,
    Color? accentPartner,
    Color? accentSage,
    Color? borderSoft,
    Color? ruleStrong,
    Color? warningTone,
    Color? bubbleUserBg,
    Color? bubbleUserText,
    Color? bubblePartnerBg,
  }) {
    return AppPalette(
      brightness: brightness ?? this.brightness,
      bgCanvas: bgCanvas ?? this.bgCanvas,
      bgSurface: bgSurface ?? this.bgSurface,
      bgSurfaceAlt: bgSurfaceAlt ?? this.bgSurfaceAlt,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      accentUser: accentUser ?? this.accentUser,
      accentUserSoft: accentUserSoft ?? this.accentUserSoft,
      accentPartner: accentPartner ?? this.accentPartner,
      accentSage: accentSage ?? this.accentSage,
      borderSoft: borderSoft ?? this.borderSoft,
      ruleStrong: ruleStrong ?? this.ruleStrong,
      warningTone: warningTone ?? this.warningTone,
      bubbleUserBg: bubbleUserBg ?? this.bubbleUserBg,
      bubbleUserText: bubbleUserText ?? this.bubbleUserText,
      bubblePartnerBg: bubblePartnerBg ?? this.bubblePartnerBg,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      // Brightness is discrete — snap at the midpoint.
      brightness: t < 0.5 ? brightness : other.brightness,
      bgCanvas: Color.lerp(bgCanvas, other.bgCanvas, t)!,
      bgSurface: Color.lerp(bgSurface, other.bgSurface, t)!,
      bgSurfaceAlt: Color.lerp(bgSurfaceAlt, other.bgSurfaceAlt, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accentUser: Color.lerp(accentUser, other.accentUser, t)!,
      accentUserSoft: Color.lerp(accentUserSoft, other.accentUserSoft, t)!,
      accentPartner: Color.lerp(accentPartner, other.accentPartner, t)!,
      accentSage: Color.lerp(accentSage, other.accentSage, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      ruleStrong: Color.lerp(ruleStrong, other.ruleStrong, t)!,
      warningTone: Color.lerp(warningTone, other.warningTone, t)!,
      bubbleUserBg: Color.lerp(bubbleUserBg, other.bubbleUserBg, t)!,
      bubbleUserText: Color.lerp(bubbleUserText, other.bubbleUserText, t)!,
      bubblePartnerBg: Color.lerp(
        bubblePartnerBg,
        other.bubblePartnerBg,
        t,
      )!,
    );
  }
}

/// Reads the active [AppPalette] off the inherited theme. Call sites use
/// `context.palette.x` where they once used `TwilightColors.x`.
extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}

/// Builds a Material [ThemeData] from [p]. Registers the palette as a theme
/// extension and themes the Material popups (app bar, dialogs, sheets, menus,
/// snackbars) so they adapt without per-widget edits. Text styles carry
/// geometry only ([TwilightType]); color comes from [textTheme]/onSurface.
ThemeData buildAppTheme(AppPalette p) {
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accentUser,
    onPrimary: p.brightness == Brightness.dark
        ? const Color(0xFF2A0F1C)
        : Colors.white,
    secondary: p.accentSage,
    onSecondary: Colors.white,
    surface: p.bgSurface,
    onSurface: p.textPrimary,
    error: p.warningTone,
    onError: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bgCanvas,
    fontFamily: 'Inter',
    extensions: [p],
    dividerTheme: DividerThemeData(color: p.borderSoft),
    dialogTheme: DialogThemeData(backgroundColor: p.bgSurface),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.bgSurface),
    popupMenuTheme: PopupMenuThemeData(color: p.bgSurface),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.bgSurfaceAlt,
      contentTextStyle: TextStyle(color: p.textPrimary),
    ),
  );
}
