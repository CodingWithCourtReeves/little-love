import 'package:flutter/material.dart';

/// Editorial type scale. One typeface (Inter), multiple voices.
/// Use these instead of raw Text(style: ...) so every screen rhymes.
///
/// These carry **geometry only** — no color. Color comes from the active
/// [AppPalette] at the call site (`...copyWith(color: context.palette.x)`),
/// so text recolors with the light/dark theme. `display`/`title`/`body` read
/// as primary text; `annotation`/`lede` as muted.
class TwilightType {
  static const _f = 'Inter';

  /// Display headline — auth screens, empty states. Tight, weighty.
  static const display = TextStyle(
    fontFamily: _f,
    fontSize: 32,
    height: 1.12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.7,
  );

  /// Mid headline — section titles within a screen.
  static const title = TextStyle(
    fontFamily: _f,
    fontSize: 20,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.25,
  );

  /// Body — composer text, bubble text, prose.
  static const body = TextStyle(
    fontFamily: _f,
    fontSize: 15,
    height: 1.5,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
  );

  /// Annotation — sidebar section headers, step markers, kbd hints.
  /// Wide tracking so it reads like a footer caption.
  static const annotation = TextStyle(
    fontFamily: _f,
    fontSize: 11,
    height: 1.0,
    fontWeight: FontWeight.w500,
    letterSpacing: 2.4,
  );

  /// Muted body — sub-copy under headlines.
  static const lede = TextStyle(
    fontFamily: _f,
    fontSize: 14,
    height: 1.6,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
  );
}
