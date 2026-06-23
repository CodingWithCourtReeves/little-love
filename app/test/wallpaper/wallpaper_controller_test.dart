import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to twilight + doodles on when prefs empty', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(wallpaperControllerProvider), WallpaperSelection.defaults);
  });

  test('setGradient + setDoodles persist and re-read', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c
        .read(wallpaperControllerProvider.notifier)
        .setGradient(WallpaperGradient.deepDusk);
    await c.read(wallpaperControllerProvider.notifier).setDoodles(false);
    expect(
      c.read(wallpaperControllerProvider),
      const WallpaperSelection(
        gradient: WallpaperGradient.deepDusk,
        doodles: false,
      ),
    );

    // Fresh container reads the persisted values back.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    await c2.read(wallpaperControllerProvider.notifier).ensureLoaded();
    expect(
      c2.read(wallpaperControllerProvider).gradient,
      WallpaperGradient.deepDusk,
    );
    expect(c2.read(wallpaperControllerProvider).doodles, isFalse);
  });

  test('drift bump increments', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(wallpaperDriftProvider), 0);
    c.read(wallpaperDriftProvider.notifier).bump();
    expect(c.read(wallpaperDriftProvider), 1);
  });
}
