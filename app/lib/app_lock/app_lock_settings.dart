/// The user's app-lock preferences: whether Little Love asks for Face ID (or
/// the iPhone passcode) and how long it may sit in the background before it
/// asks again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long the app may be away (in the background) before it locks again.
/// The choices mirror the usual messaging-app set; [oneMinute] is the default.
enum LockAfter {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes'),
  oneHour(Duration(hours: 1), 'After 1 hour');

  const LockAfter(this.duration, this.label);

  final Duration duration;
  final String label;
}

class AppLockSettings {
  const AppLockSettings({
    this.enabled = true,
    this.lockAfter = LockAfter.oneMinute,
  });

  /// On by default: the chats are private, so a new install starts locked.
  final bool enabled;
  final LockAfter lockAfter;

  AppLockSettings copyWith({bool? enabled, LockAfter? lockAfter}) =>
      AppLockSettings(
        enabled: enabled ?? this.enabled,
        lockAfter: lockAfter ?? this.lockAfter,
      );

  static const _enabledKey = 'appLock.enabled';
  static const _lockAfterKey = 'appLock.lockAfter';

  /// Read the persisted settings. Called once in `main` before the first
  /// frame, so a cold start already knows whether to show the lock (no flash
  /// of chats while prefs load, and no flash of the lock for someone who
  /// turned it off). An unknown stored value falls back to the default.
  static Future<AppLockSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_lockAfterKey);
    return AppLockSettings(
      enabled: prefs.getBool(_enabledKey) ?? true,
      lockAfter: LockAfter.values.firstWhere(
        (v) => v.name == stored,
        orElse: () => LockAfter.oneMinute,
      ),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setString(_lockAfterKey, lockAfter.name);
  }

  /// Forget the choices on sign-out, so the next account on this device starts
  /// from the defaults (locked, after 1 minute).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_enabledKey);
    await prefs.remove(_lockAfterKey);
  }
}

/// The settings read at launch. `main` overrides this with
/// [AppLockSettings.load]; without an override (tests, the signed-out choice
/// screen) it is the defaults.
final initialAppLockSettingsProvider = Provider<AppLockSettings>(
  (ref) => const AppLockSettings(),
);

class AppLockSettingsNotifier extends Notifier<AppLockSettings> {
  @override
  AppLockSettings build() => ref.watch(initialAppLockSettingsProvider);

  Future<void> setEnabled(bool value) =>
      _update(state.copyWith(enabled: value));

  Future<void> setLockAfter(LockAfter value) =>
      _update(state.copyWith(lockAfter: value));

  /// Sign-out: back to the defaults, in memory and on disk. Not an
  /// invalidate, which would rebuild from the launch-time settings of the
  /// account that just left.
  Future<void> reset() async {
    state = const AppLockSettings();
    await AppLockSettings.clear();
  }

  Future<void> _update(AppLockSettings next) async {
    state = next;
    await next.save();
  }
}

final appLockSettingsProvider =
    NotifierProvider<AppLockSettingsNotifier, AppLockSettings>(
      AppLockSettingsNotifier.new,
    );
