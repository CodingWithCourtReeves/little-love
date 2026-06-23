import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wallpaper/wallpaper_controller.dart';
import '../wallpaper/wallpaper_selection.dart';
import 'app_palette.dart';

/// The active product palette, derived from the wallpaper each user picks
/// locally: the wallpaper's [WallpaperGradient.brightness] selects the light
/// or dark [AppPalette]. The app root builds `MaterialApp.theme` from this, so
/// changing the wallpaper recolors the whole product.
///
/// The wallpaper controller resolves synchronously to its defaults (Twilight →
/// dark) before its async load, so there is no light-flash on cold start; when
/// the persisted choice loads, the theme lerps to it.
final paletteProvider = Provider<AppPalette>((ref) {
  final selection = ref.watch(wallpaperControllerProvider);
  return AppPalette.of(selection.gradient.brightness);
});
