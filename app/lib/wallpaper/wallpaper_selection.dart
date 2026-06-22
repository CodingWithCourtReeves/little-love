import 'package:flutter/material.dart';

/// The four shipped wallpaper gradients. Hex values are the approved
/// mockup palettes; each renders as a soft 4-point radial mesh.
enum WallpaperGradient { rose, twilight, mauveSage, deepDusk }

extension WallpaperGradientData on WallpaperGradient {
  String get label => switch (this) {
    WallpaperGradient.rose => 'Rosé',
    WallpaperGradient.twilight => 'Twilight',
    WallpaperGradient.mauveSage => 'Mauve & Sage',
    WallpaperGradient.deepDusk => 'Deep Dusk',
  };

  /// Four mesh colors, mapped to the four animated anchors in order.
  List<Color> get colors => switch (this) {
    WallpaperGradient.rose => const [
      Color(0xFFF7E3E8),
      Color(0xFFE8C8D2),
      Color(0xFFD9B8C6),
      Color(0xFFC98EA3),
    ],
    WallpaperGradient.twilight => const [
      Color(0xFF5B3450),
      Color(0xFFA04A6A),
      Color(0xFF8A5A7A),
      Color(0xFFC98EA3),
    ],
    WallpaperGradient.mauveSage => const [
      Color(0xFFC98EA3),
      Color(0xFFE2D3D8),
      Color(0xFFA9C2AC),
      Color(0xFF6E9B7A),
    ],
    WallpaperGradient.deepDusk => const [
      Color(0xFF241A28),
      Color(0xFF5E2C49),
      Color(0xFFA04A6A),
      Color(0xFF3E2C3A),
    ],
  };

  /// Fill behind the mesh (covers gaps where the radial falloffs fade out).
  Color get base => switch (this) {
    WallpaperGradient.rose => const Color(0xFFEFDCE2),
    WallpaperGradient.twilight => const Color(0xFF6B3D5C),
    WallpaperGradient.mauveSage => const Color(0xFFD8C9CF),
    WallpaperGradient.deepDusk => const Color(0xFF2A1F2A),
  };

  /// Doodle stroke color: light over dark palettes, dark over light ones.
  Color get doodleInk => switch (this) {
    WallpaperGradient.rose => const Color(0x14000000),
    WallpaperGradient.mauveSage => const Color(0x14000000),
    WallpaperGradient.twilight => const Color(0x24FFFFFF),
    WallpaperGradient.deepDusk => const Color(0x2BFFFFFF),
  };
}

class WallpaperSelection {
  const WallpaperSelection({required this.gradient, required this.doodles});

  final WallpaperGradient gradient;
  final bool doodles;

  static const WallpaperSelection defaults = WallpaperSelection(
    gradient: WallpaperGradient.twilight,
    doodles: true,
  );

  WallpaperSelection copyWith({WallpaperGradient? gradient, bool? doodles}) =>
      WallpaperSelection(
        gradient: gradient ?? this.gradient,
        doodles: doodles ?? this.doodles,
      );

  @override
  bool operator ==(Object other) =>
      other is WallpaperSelection &&
      other.gradient == gradient &&
      other.doodles == doodles;

  @override
  int get hashCode => Object.hash(gradient, doodles);
}

/// Anchor configurations (unit space, 0..1) the gradient drifts between on
/// each send. Index advances per send and wraps.
const List<List<Offset>> kWallpaperDriftSlots = [
  [
    Offset(0.18, 0.18),
    Offset(0.84, 0.24),
    Offset(0.22, 0.86),
    Offset(0.86, 0.80),
  ],
  [
    Offset(0.30, 0.12),
    Offset(0.74, 0.34),
    Offset(0.14, 0.74),
    Offset(0.92, 0.68),
  ],
  [
    Offset(0.12, 0.30),
    Offset(0.88, 0.16),
    Offset(0.30, 0.92),
    Offset(0.78, 0.88),
  ],
];
