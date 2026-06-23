import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallpaper_selection.dart';

const _kGradient = 'wallpaper.gradient';
const _kDoodles = 'wallpaper.doodles';

/// Per-device wallpaper choice, persisted via shared_preferences. [build]
/// returns the default immediately and hydrates asynchronously so the UI has
/// a sane background on first frame.
class WallpaperController extends Notifier<WallpaperSelection> {
  Future<void>? _loading;

  @override
  WallpaperSelection build() {
    _loading = _load();
    return WallpaperSelection.defaults;
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(_kGradient);
    final gradient = WallpaperGradient.values
        .where((g) => g.name == name)
        .firstOrNull;
    final doodles = p.getBool(_kDoodles);
    if (gradient != null || doodles != null) {
      state = WallpaperSelection(
        gradient: gradient ?? state.gradient,
        doodles: doodles ?? state.doodles,
      );
    }
  }

  /// Test/seam helper: await initial hydration.
  Future<void> ensureLoaded() => _loading ?? Future.value();

  Future<void> setGradient(WallpaperGradient g) async {
    state = state.copyWith(gradient: g);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kGradient, g.name);
  }

  Future<void> setDoodles(bool on) async {
    state = state.copyWith(doodles: on);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDoodles, on);
  }
}

final wallpaperControllerProvider =
    NotifierProvider<WallpaperController, WallpaperSelection>(
      WallpaperController.new,
    );

/// A monotonically increasing counter the conversation bumps on each send;
/// the wallpaper watches it to trigger one gradient drift.
class WallpaperDrift extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final wallpaperDriftProvider = NotifierProvider<WallpaperDrift, int>(
  WallpaperDrift.new,
);
