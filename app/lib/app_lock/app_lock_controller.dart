/// Decides when Little Love is locked behind Face ID (or the iPhone passcode),
/// and when the chats are hidden behind a plain cover.
///
/// The rules:
/// - A cold start opens locked (when the lock is on).
/// - Leaving the app covers it at once, so the app-switcher snapshot and a
///   glance at the screen never show chats.
/// - Coming back within the chosen grace ([LockAfter]) just lifts the cover;
///   coming back later locks and asks for Face ID.
/// - Only real backgrounding (`hidden`/`paused`) starts the grace clock. A
///   plain `inactive` (Control Center, a system alert, our own Face ID sheet)
///   covers but never locks, which is what keeps the Face ID prompt from
///   re-locking the app the moment it closes.
/// - A call on screen is never interrupted by a prompt: answering from CallKit
///   connects straight away, and the chats stay locked behind the call.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calling/call_controller.dart';
import '../diagnostics/crash_reporting.dart';
import '../identity/account_local.dart';
import '../identity/providers.dart';
import 'app_lock_settings.dart';
import 'device_auth.dart';

enum AppLockStatus {
  /// The app is showing normally.
  unlocked,

  /// The app is leaving the foreground (or briefly interrupted): a plain cover
  /// hides the chats, but no Face ID is needed to lift it.
  covered,

  /// Face ID (or the passcode) is needed to see the chats.
  locked,
}

class AppLockController extends Notifier<AppLockStatus>
    with WidgetsBindingObserver {
  /// When the app last went to the background; null while in the foreground.
  DateTime? _leftAt;

  /// Re-entrancy guard for [unlock]; reset in `finally`.
  bool _authenticating = false;

  /// Set once the account has loaded as signed out, so the next account to
  /// appear is a sign-up or sign-in in this session rather than a launch.
  bool _sawSignedOut = false;

  /// A prompt was wanted while the app wasn't yet active (on a cold start iOS
  /// often reports `resumed` only after the first frame), so ask on the next
  /// `resumed`. Cleared as soon as a prompt starts, so the Face ID sheet's own
  /// inactive/resumed can never re-trigger it.
  bool _promptPending = false;

  @override
  AppLockStatus build() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    ref.onDispose(() => binding.removeObserver(this));
    ref.listen<AsyncValue<LocalAccount?>>(accountProvider, (prev, next) {
      // A refresh passes through loading; judge only settled values.
      if (next.isLoading) return;
      if (next.valueOrNull == null) {
        if (next.hasValue) _sawSignedOut = true;
        return;
      }
      if (_sawSignedOut) {
        // Signed up or signed in during this session: that is presence
        // enough, so the lock from the cold start must not appear now.
        _sawSignedOut = false;
        state = AppLockStatus.unlocked;
      } else if (prev?.valueOrNull == null) {
        // The account just loaded at launch: ask for Face ID once the first
        // frame is up (the lock screen is what that frame shows).
        SchedulerBinding.instance.addPostFrameCallback((_) => _prompt());
      }
    }, fireImmediately: true);
    return ref.read(appLockSettingsProvider).enabled
        ? AppLockStatus.locked
        : AppLockStatus.unlocked;
  }

  // Named `lifecycle`, not the base's `state`, so it doesn't shadow
  // [Notifier.state], which this method sets.
  @override
  // ignore: avoid_renaming_method_parameters
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    final settings = ref.read(appLockSettingsProvider);
    switch (lifecycle) {
      case AppLifecycleState.inactive:
        // Cover while still drawing: iOS stops rendering Flutter frames once
        // the app is in the background, so the cover must be on screen
        // before then or the app-switcher snapshot shows the chats.
        if (settings.enabled && state == AppLockStatus.unlocked) {
          state = AppLockStatus.covered;
        }
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _leftAt ??= ref.read(appLockClockProvider)();
        if (settings.enabled && state == AppLockStatus.unlocked) {
          state = AppLockStatus.covered;
        }
      case AppLifecycleState.resumed:
        _onResumed(settings);
      case AppLifecycleState.detached:
        // The engine is going away; nothing to show.
        break;
    }
  }

  void _onResumed(AppLockSettings settings) {
    final leftAt = _leftAt;
    _leftAt = null;
    if (!settings.enabled) {
      state = AppLockStatus.unlocked;
      return;
    }
    if (state == AppLockStatus.locked) {
      // Already locked (cold start, or Face ID was cancelled). Ask again only
      // after a real trip to the background or for a prompt that was waiting
      // on the app becoming active, never after our own Face ID sheet closes,
      // or cancelling it would loop.
      if (leftAt != null || _promptPending) _prompt();
      return;
    }
    final away = leftAt == null
        ? Duration.zero
        : ref.read(appLockClockProvider)().difference(leftAt);
    if (leftAt != null && away >= settings.lockAfter.duration) {
      state = AppLockStatus.locked;
      _prompt();
    } else {
      state = AppLockStatus.unlocked;
    }
  }

  /// Ask for Face ID now if the lock screen is what the user is looking at.
  void _prompt() {
    if (state != AppLockStatus.locked) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      _promptPending = true;
      return;
    }
    // Signed out: there are no chats to protect and the lock isn't shown.
    if (ref.read(accountProvider).valueOrNull == null) return;
    // The call screen sits above the lock; the user taps Unlock after the call.
    if (ref.read(callOnScreenProvider)()) return;
    _promptPending = false;
    unawaited(unlock());
  }

  /// Ask for Face ID (falling back to the passcode) and unlock on success.
  /// A cancel or failure leaves the app locked; the lock screen's Unlock
  /// button calls this again. Never throws.
  Future<void> unlock() async {
    if (_authenticating || state != AppLockStatus.locked) return;
    _authenticating = true;
    try {
      final auth = ref.read(deviceAuthProvider);
      if (!await auth.isAvailable()) {
        // No passcode set on this iPhone, so there is nothing to check
        // against. Anyone holding the phone already has it open.
        state = AppLockStatus.unlocked;
        return;
      }
      if (await auth.authenticate()) {
        // If the user left the app while the sheet was finishing, the app is
        // already in the background and can't draw: keep the cover so the
        // app-switcher snapshot doesn't show the chats. The next `resumed`
        // lifts it (or locks again if the grace ran out).
        state =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed
            ? AppLockStatus.unlocked
            : AppLockStatus.covered;
      }
    } catch (e, st) {
      debugPrint('lock: authenticate failed');
      reportFault(e, st, context: 'app_lock_authenticate');
    } finally {
      _authenticating = false;
    }
  }
}

/// The clock the grace period is measured with. Tests override it.
final appLockClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Whether the in-app call screen is up right now. A seam so the lock's tests
/// don't have to build the real call stack.
final callOnScreenProvider = Provider<bool Function()>((ref) {
  final calls = ref.watch(callControllerProvider);
  return () => calls.state.value.showsCallScreen;
});

final appLockProvider = NotifierProvider<AppLockController, AppLockStatus>(
  AppLockController.new,
);
