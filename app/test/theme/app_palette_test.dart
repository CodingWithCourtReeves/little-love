import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/theme/palette_provider.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('light and dark carry their declared brightness', () {
    expect(AppPalette.light.brightness, Brightness.light);
    expect(AppPalette.dark.brightness, Brightness.dark);
  });

  test('of() maps a brightness to the matching palette', () {
    expect(AppPalette.of(Brightness.light), same(AppPalette.light));
    expect(AppPalette.of(Brightness.dark), same(AppPalette.dark));
  });

  test('light and dark differ on every surface/text/accent token', () {
    const l = AppPalette.light;
    const d = AppPalette.dark;
    // A few representative tokens must actually flip between the two.
    expect(l.bgCanvas, isNot(d.bgCanvas));
    expect(l.bgSurface, isNot(d.bgSurface));
    expect(l.textPrimary, isNot(d.textPrimary));
    expect(l.textMuted, isNot(d.textMuted));
    expect(l.accentUser, isNot(d.accentUser));
    expect(l.bubbleUserBg, isNot(d.bubbleUserBg));
    // The you/partner two-hue distinction survives in both palettes.
    expect(l.accentUser, isNot(l.accentPartner));
    expect(d.accentUser, isNot(d.accentPartner));
  });

  test('lerp blends colors and snaps brightness at the midpoint', () {
    final mid = AppPalette.light.lerp(AppPalette.dark, 0.5);
    // A blended color is neither endpoint.
    expect(mid.bgCanvas, isNot(AppPalette.light.bgCanvas));
    expect(mid.bgCanvas, isNot(AppPalette.dark.bgCanvas));
    // Brightness is discrete — below the midpoint it stays with the start.
    expect(
      AppPalette.light.lerp(AppPalette.dark, 0.4).brightness,
      Brightness.light,
    );
    expect(
      AppPalette.light.lerp(AppPalette.dark, 0.6).brightness,
      Brightness.dark,
    );
  });

  test('buildAppTheme registers the palette and matches its brightness', () {
    final theme = buildAppTheme(AppPalette.dark);
    expect(theme.brightness, Brightness.dark);
    expect(theme.extension<AppPalette>(), same(AppPalette.dark));
    expect(theme.scaffoldBackgroundColor, AppPalette.dark.bgCanvas);
  });

  group('paletteProvider follows the wallpaper brightness', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('default wallpaper (Twilight) yields the dark palette', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(paletteProvider), same(AppPalette.dark));
    });

    test('switching to a light wallpaper yields the light palette', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(wallpaperControllerProvider.notifier)
          .setGradient(WallpaperGradient.rose);
      expect(container.read(paletteProvider), same(AppPalette.light));
    });
  });
}
