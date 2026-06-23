import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/keystore.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/identity/sign_out.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/pairing/deep_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pure-async stores (no `dart:io`): real file I/O never completes inside the
/// `testWidgets` fake-async zone, which would hang `signOut`'s awaits. These
/// keep the wipe steps microtask-only so `pump()` deterministically settles
/// everything except the gated outbox clear we're actually probing.
class _NoopAccountStore extends AccountLocalStore {
  _NoopAccountStore() : super(homeDirectory: Directory.systemTemp);
  @override
  Future<LocalAccount?> load() async => null;
  @override
  Future<void> delete() async {}
}

class _NoopReadStateStore extends ReadStateStore {
  _NoopReadStateStore() : super(homeDirectory: Directory.systemTemp);
  @override
  Future<void> clear() async {}
}

/// Outbox whose `clear()` blocks on an external gate, so a test can observe
/// whether `signOut` waits for the wipe to finish before completing.
class _GatedOutbox implements OutboxStore {
  _GatedOutbox(this._gate);
  final Future<void> _gate;
  bool cleared = false;

  @override
  Future<void> clear() async {
    await _gate;
    cleared = true;
  }

  @override
  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required Map<String, String> bodies,
    DateTime? createdAt,
  }) async {}

  @override
  Future<List<OutboxRow>> pending() async => const [];

  @override
  Future<OutboxRow?> lookup(String clientMsgId) async => null;

  @override
  Future<bool> remove(String clientMsgId) async => false;

  @override
  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  }) async {}
}

/// Mount a trivial Consumer purely to capture a real [WidgetRef] for
/// [signOut], which the production caller (HomeScreen) passes from a widget.
Future<WidgetRef> _mountRef(WidgetTester t, List<Override> overrides) async {
  late WidgetRef captured;
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  // signOut clears the SharedPreferences-backed profile avatar cache; the mock
  // makes getInstance() resolve on a microtask instead of hanging the fake-async
  // zone (real platform-channel I/O never completes here).
  setUp(() => SharedPreferences.setMockInitialValues({}));

  List<Override> baseOverrides(OutboxStore outbox) => [
    keystoreProvider.overrideWithValue(InMemoryKeystore()),
    accountLocalStoreProvider.overrideWithValue(_NoopAccountStore()),
    readStateStoreProvider.overrideWithValue(_NoopReadStateStore()),
    outboxStoreProvider.overrideWith((_) async => outbox),
  ];

  testWidgets('signOut does not complete until the outbox clear resolves', (
    t,
  ) async {
    final gate = Completer<void>();
    final outbox = _GatedOutbox(gate.future);
    final ref = await _mountRef(t, baseOverrides(outbox));

    var done = false;
    final fut = signOut(ref).then((_) => done = true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 10));

    // Outbox wipe is still gated, so sign-out must not have completed: a new
    // account could otherwise re-send the previous user's queued messages.
    expect(done, isFalse, reason: 'sign-out must await the outbox clear');
    expect(outbox.cleared, isFalse);

    gate.complete();
    await t.pumpAndSettle();
    await fut;

    expect(outbox.cleared, isTrue);
    expect(done, isTrue);
  });

  testWidgets('signOut preserves a captured pair-link code', (t) async {
    final outbox = _GatedOutbox(Future<void>.value());
    final ref = await _mountRef(t, baseOverrides(outbox));

    // The invitee flow is "tap /pair/<code> link → sign out of the old account
    // → sign up → auto-pair". The cold-launch link is pulled from the native
    // buffer only once, so the captured code MUST survive sign-out for the new
    // account's PairingScreen to consume it. Regression guard: sign-out must
    // not clear it.
    ref.read(pendingPairCodeProvider.notifier).state = 'amber-fern-locket-tide';

    await signOut(ref);
    await t.pumpAndSettle();

    expect(ref.read(pendingPairCodeProvider), 'amber-fern-locket-tide');
  });
}
