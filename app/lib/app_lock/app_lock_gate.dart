/// The cover drawn over every route while the app is covered or locked. It
/// sits under `MaterialApp.builder`, above the message banners (so a banner's
/// preview never shows over it) and below the call screen (so a call answered
/// from CallKit is usable straight away).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/providers.dart';
import '../onboarding/heart_lock.dart';
import '../theme/app_palette.dart';
import '../theme/twilight.dart';
import 'app_lock_controller.dart';

class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(appLockProvider);
    // Drop the keyboard when locking, or typing would land in the hidden
    // composer (and the keyboard would float over the lock screen).
    ref.listen(appLockProvider, (_, next) {
      if (next == AppLockStatus.locked) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
    });
    // Signed out: no chats to hide, and the signup screens must stay usable.
    final signedIn = ref.watch(accountProvider).valueOrNull != null;
    if (!signedIn || status == AppLockStatus.unlocked) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      // Swallow every touch and hide the chats underneath from VoiceOver.
      child: BlockSemantics(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: _LockScreen(
            locked: status == AppLockStatus.locked,
            onUnlock: () => ref.read(appLockProvider.notifier).unlock(),
          ),
        ),
      ),
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
