import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';

void main() {
  test('default is twilight + doodles on', () {
    expect(WallpaperSelection.defaults.gradient, WallpaperGradient.twilight);
    expect(WallpaperSelection.defaults.doodles, isTrue);
  });

  test('every gradient defines 4 colors, a base, a label and an ink', () {
    for (final g in WallpaperGradient.values) {
      expect(g.colors.length, 4, reason: '${g.name} needs 4 colors');
      expect(g.label, isNotEmpty);
      expect(g.base, isA<Color>());
      expect(g.doodleInk, isA<Color>());
    }
  });

  test('brightness: pale palettes are light, plum ones are dark', () {
    expect(WallpaperGradient.rose.brightness, Brightness.light);
    expect(WallpaperGradient.mauveSage.brightness, Brightness.light);
    expect(WallpaperGradient.twilight.brightness, Brightness.dark);
    expect(WallpaperGradient.deepDusk.brightness, Brightness.dark);
  });

  test('copyWith + equality', () {
    const a = WallpaperSelection(
      gradient: WallpaperGradient.rose,
      doodles: false,
    );
    expect(
      a.copyWith(doodles: true),
      const WallpaperSelection(gradient: WallpaperGradient.rose, doodles: true),
    );
    expect(a, a.copyWith());
  });

  test('drift slots are well-formed', () {
    expect(kWallpaperDriftSlots.length, greaterThanOrEqualTo(2));
    for (final slot in kWallpaperDriftSlots) {
      expect(slot.length, 4);
    }
  });
}
