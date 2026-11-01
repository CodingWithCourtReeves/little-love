/// Draws the lock over [child] (every route plus the message banners) while
/// the app is covered or locked. It sits in `MaterialApp.builder` below the
/// call screen, so a call answered from CallKit is usable straight away.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/providers.dart';
import '../onboarding/heart_lock.dart';
import '../theme/app_palette.dart';
import '../theme/twilight.dart';
import 'app_lock_controller.dart';

class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});

  /// The app's routes and banners: everything the lock hides.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appLockProvider);
    // Signed out: no chats to hide, and the signup screens must stay usable.
    final signedIn = ref.watch(accountProvider).valueOrNull != null;
    final shown = signedIn && status != AppLockStatus.unlocked;
    return Stack(
      fit: StackFit.expand,
      children: [
        // While locked nothing behind the lock may take focus: locking drops
        // the keyboard, and a field that autofocuses (search) can't raise it
        // over the lock screen or take typing meant for nobody. Only when
        // locked, so a glance at Control Center keeps the keyboard.
        ExcludeFocus(
          excluding: shown && status == AppLockStatus.locked,
          child: child,
        ),
        if (shown)
          // Swallow every touch and hide the chats from VoiceOver.
          BlockSemantics(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              child: _LockScreen(
                locked: status == AppLockStatus.locked,
                onUnlock: () => ref.read(appLockProvider.notifier).unlock(),
              ),
            ),
          ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.locked, required this.onUnlock});

  /// False for the plain cover shown while leaving the app: no button, since
  /// it lifts on its own when the app comes back within the grace period.
  final bool locked;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      key: const Key('app-lock-screen'),
      color: palette.bgCanvas,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              const Center(child: HeartLock(size: 160)),
              const SizedBox(height: 28),
              Text(
                'Little Love',
                textAlign: TextAlign.center,
                style: TwilightType.display.copyWith(
                  color: palette.textPrimary,
                ),
              ),
              const Spacer(flex: 4),
              // Keep the button's space when covered so nothing jumps when the
              // cover turns into the lock.
              Visibility(
                visible: locked,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: FilledButton(
                  key: const Key('app-lock-unlock'),
                  style: FilledButton.styleFrom(
                    backgroundColor: palette.accentUser,
                    foregroundColor: palette.bgCanvas,
                    minimumSize: const Size.fromHeight(52),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onPressed: onUnlock,
                  child: const Text('Unlock'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
