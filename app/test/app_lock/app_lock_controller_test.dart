import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/app_lock/app_lock_controller.dart';
import 'package:littlelove/app_lock/app_lock_gate.dart';
import 'package:littlelove/app_lock/app_lock_settings.dart';
import 'package:littlelove/app_lock/device_auth.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/theme/app_palette.dart';

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 9),
);

class _FakeAuth implements DeviceAuth {
  bool available = true;

  /// What the next Face ID sheet answers.
  bool answer = true;
  int prompts = 0;

  /// When set, the sheet stays up until the test completes this.
  Completer<bool>? sheet;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate() async {
    prompts++;
    return sheet?.future ?? Future.value(answer);
  }
}

class _Harness {
  _Harness(this.container, this.auth);
  final ProviderContainer container;
  final _FakeAuth auth;
  var now = DateTime.utc(2026, 10, 31, 12);
  var callOnScreen = false;
  LocalAccount? account = _account;

  AppLockStatus get status => container.read(appLockProvider);
}

/// Mount the real app-lock gate (so the controller is built the way the app
/// builds it) over a stand-in chat screen. Pass [auth] to set the cold-start
/// Face ID answer; by default it succeeds, so the test starts unlocked.
Future<_Harness> _mount(
  WidgetTester t, {
  AppLockSettings settings = const AppLockSettings(),
  _FakeAuth? auth,
  bool signedOut = false,
  AppLifecycleState launchState = AppLifecycleState.resumed,
  Widget home = const Text('a private chat'),
}) async {
  auth ??= _FakeAuth();
  late _Harness h;
  final container = ProviderContainer(
    overrides: [
      initialAppLockSettingsProvider.overrideWithValue(settings),
      deviceAuthProvider.overrideWithValue(auth),
      appLockClockProvider.overrideWithValue(() => h.now),
      callOnScreenProvider.overrideWithValue(() => h.callOnScreen),
      accountProvider.overrideWith((ref) async => h.account),
    ],
  );
  addTearDown(container.dispose);
  h = _Harness(container, auth);
  if (signedOut) h.account = null;
  t.binding.handleAppLifecycleStateChanged(launchState);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [AppLockGate(child: child!)],
        ),
        home: Scaffold(body: home),
      ),
    ),
  );
  await t.pump();
  await t.pump();
  return h;
}

/// Swipe home and come back [away] later.
Future<void> _leaveAndReturn(WidgetTester t, _Harness h, Duration away) async {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await t.pump();
  h.now = h.now.add(away);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await t.pump();
  await t.pump();
}

void main() {
  testWidgets('a cold start opens locked and asks for Face ID right away', (
    t,
  ) async {
    final auth = _FakeAuth()..answer = false;
    final h = await _mount(t, auth: auth);
    expect(auth.prompts, 1);
    expect(h.status, AppLockStatus.locked);
    expect(find.byKey(const Key('app-lock-screen')), findsOneWidget);

    auth.answer = true;
    await t.tap(find.byKey(const Key('app-lock-unlock')));
    await t.pump();
    expect(h.status, AppLockStatus.unlocked);
    expect(find.byKey(const Key('app-lock-screen')), findsNothing);
  });

  testWidgets('with the lock off, a cold start opens straight to the chats', (
    t,
  ) async {
    final h = await _mount(t, settings: const AppLockSettings(enabled: false));
    expect(h.status, AppLockStatus.unlocked);
    expect(h.auth.prompts, 0);
    expect(find.byKey(const Key('app-lock-screen')), findsNothing);
  });

  testWidgets('leaving the app covers the chats before it goes to the '
      'background (the app-switcher snapshot)', (t) async {
    final h = await _mount(t);
    expect(h.status, AppLockStatus.unlocked);

    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(h.status, AppLockStatus.covered);
    expect(find.byKey(const Key('app-lock-screen')), findsOneWidget);
    // The plain cover has no Unlock button to tap.
    final unlock = t.widget<Visibility>(
      find.ancestor(
        of: find.byKey(const Key('app-lock-unlock')),
        matching: find.byType(Visibility),
      ),
    );
    expect(unlock.visible, isFalse);
  });

  testWidgets('coming back within the grace period lifts the cover with no '
      'Face ID', (t) async {
    final h = await _mount(t);
    final before = h.auth.prompts;
    await _leaveAndReturn(t, h, const Duration(seconds: 59));
    expect(h.status, AppLockStatus.unlocked);
    expect(h.auth.prompts, before);
  });

  testWidgets('coming back after the grace period locks and asks for Face ID', (
    t,
  ) async {
    final h = await _mount(t);
    h.auth.answer = false;
    final before = h.auth.prompts;
    await _leaveAndReturn(t, h, const Duration(minutes: 1));
    expect(h.status, AppLockStatus.locked);
    expect(h.auth.prompts, before + 1);
  });

  testWidgets('"Immediately" locks on any return', (t) async {
    final h = await _mount(
      t,
      settings: const AppLockSettings(lockAfter: LockAfter.immediately),
    );
    h.auth.answer = false;
    await _leaveAndReturn(t, h, Duration.zero);
    expect(h.status, AppLockStatus.locked);
  });

  testWidgets('a longer grace keeps the app open for that long', (t) async {
    final h = await _mount(
      t,
      settings: const AppLockSettings(lockAfter: LockAfter.fifteenMinutes),
    );
    await _leaveAndReturn(t, h, const Duration(minutes: 14));
    expect(h.status, AppLockStatus.unlocked);
    h.auth.answer = false;
    await _leaveAndReturn(t, h, const Duration(minutes: 15));
    expect(h.status, AppLockStatus.locked);
  });

  testWidgets('cancelling Face ID stays locked and does not ask again when '
      'its own sheet closes (no prompt loop)', (t) async {
    final auth = _FakeAuth()..answer = false;
    final h = await _mount(t, auth: auth);
    expect(auth.prompts, 1);

    // The Face ID sheet makes the app inactive, then active, without ever
    // leaving the foreground.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    h.now = h.now.add(const Duration(hours: 2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    await t.pump();

    expect(h.status, AppLockStatus.locked);
    expect(auth.prompts, 1);
  });

  testWidgets('a brief interruption (Control Center) covers but never locks', (
    t,
  ) async {
    final h = await _mount(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    h.now = h.now.add(const Duration(hours: 2));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(h.status, AppLockStatus.unlocked);
  });

  testWidgets('a cancelled lock stays locked after a quick trip away', (
    t,
  ) async {
    final auth = _FakeAuth()..answer = false;
    final h = await _mount(t, auth: auth);
    await _leaveAndReturn(t, h, const Duration(seconds: 5));
    expect(h.status, AppLockStatus.locked);
    expect(auth.prompts, 2, reason: 'asks again after a real trip away');
  });

  testWidgets('a call on screen is never interrupted by Face ID; the chats '
      'stay locked behind it', (t) async {
    final h = await _mount(t);
    h.callOnScreen = true;
    final before = h.auth.prompts;
    await _leaveAndReturn(t, h, const Duration(minutes: 5));
    expect(h.status, AppLockStatus.locked);
    expect(h.auth.prompts, before);
  });

  testWidgets('signing up in this session does not then show the lock', (
    t,
  ) async {
    final h = await _mount(t, signedOut: true);
    expect(h.auth.prompts, 0, reason: 'nothing to protect while signed out');
    expect(find.byKey(const Key('app-lock-screen')), findsNothing);

    h.account = _account;
    h.container.invalidate(accountProvider);
    await t.pump();
    await t.pump();

    expect(h.status, AppLockStatus.unlocked);
    expect(h.auth.prompts, 0);
    expect(find.byKey(const Key('app-lock-screen')), findsNothing);
  });

  testWidgets('saving a profile change does not lock or ask again', (t) async {
    final h = await _mount(t);
    final before = h.auth.prompts;
    h.container.invalidate(accountProvider);
    await t.pump();
    await t.pump();
    expect(h.status, AppLockStatus.unlocked);
    expect(h.auth.prompts, before);
  });

  testWidgets('an iPhone with no passcode opens without asking', (t) async {
    final auth = _FakeAuth()..available = false;
    final h = await _mount(t, auth: auth);
    expect(h.status, AppLockStatus.unlocked);
    expect(auth.prompts, 0);
  });

  testWidgets('a cold start that becomes active only after the first frame '
      'still asks for Face ID, once', (t) async {
    final auth = _FakeAuth()..answer = false;
    final h = await _mount(
      t,
      auth: auth,
      launchState: AppLifecycleState.inactive,
    );
    expect(auth.prompts, 0, reason: 'not on screen yet');
    expect(h.status, AppLockStatus.locked);

    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(auth.prompts, 1);

    // Its own sheet closing (inactive, resumed) must not ask again.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(auth.prompts, 1);
    expect(h.status, AppLockStatus.locked);
  });

  testWidgets('unlocking just as the user leaves keeps the chats covered in '
      'the background', (t) async {
    final h = await _mount(t);
    h.auth.sheet = Completer<bool>();
    await _leaveAndReturn(t, h, const Duration(minutes: 2));
    expect(h.status, AppLockStatus.locked);

    // Face ID succeeds after the user has already swiped home.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    h.auth.sheet!.complete(true);
    await t.pump();
    expect(h.status, AppLockStatus.covered);
    expect(find.byKey(const Key('app-lock-screen')), findsOneWidget);

    // Back within the grace: the cover lifts with no second prompt.
    h.now = h.now.add(const Duration(seconds: 5));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(h.status, AppLockStatus.unlocked);
  });

  testWidgets('nothing behind the lock can take focus or raise the keyboard', (
    t,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final auth = _FakeAuth()..answer = false;
    final h = await _mount(
      t,
      auth: auth,
      home: TextField(focusNode: focus, autofocus: true),
    );
    await t.pump();
    expect(h.status, AppLockStatus.locked);
    expect(focus.hasFocus, isFalse);

    auth.answer = true;
    await t.tap(find.byKey(const Key('app-lock-unlock')));
    await t.pump();
    focus.requestFocus();
    await t.pump();
    expect(focus.hasFocus, isTrue);

    // Locking again drops the keyboard.
    auth.answer = false;
    await _leaveAndReturn(t, h, const Duration(minutes: 2));
    expect(h.status, AppLockStatus.locked);
    expect(focus.hasFocus, isFalse);
  });

  testWidgets('the lock screen swallows taps meant for the chats', (t) async {
    final auth = _FakeAuth()..answer = false;
    await _mount(t, auth: auth);
    expect(find.text('a private chat').hitTestable(), findsNothing);
  });
}
