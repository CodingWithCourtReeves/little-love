import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_search.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/keystore.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/auth/auth_gate.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../outbox/memory_outbox_store.dart';

/// A pairing transport that resolves immediately so HomeScreen's empty state
/// (PairingScreen) renders its static content — no infinite spinner, so
/// `pumpAndSettle` settles for the menu/dialog interactions below.
class _FakeTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() async => InviteCreatedFrame(
    code: 'abandon-ability-able-about',
    qrPngBase64: '',
    expiresAt: DateTime.utc(2026, 6, 20),
  );
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async => const InviteConsumedFrame(roomId: 'r1', name: '', members: []);
}

/// No-op ReadStateStore so sign-out doesn't do real file I/O, which never
/// settles under the widget-test fake-async clock.
class _FakeReadStateStore implements ReadStateStore {
  @override
  Future<Map<String, DateTime>> load() async => const {};
  @override
  Future<void> save(Map<String, DateTime> state) async {}
  @override
  Future<void> clear() async {}
}

/// No-op message store so sign-out's `clear()` doesn't hit the keychain/ffi
/// under the widget-test binding.
class _FakeMessageDb implements MessageDb {
  @override
  Future<void> clear() async {}
  @override
  Future<void> upsert(Msg msg, {required String roomId}) async {}
  @override
  Future<List<Msg>> messagesFor(String roomId) async => const [];
  @override
  Future<void> reconcile(String clientMsgId, Msg server) async {}
  @override
  Future<void> applyDelete(String t, {required String requestedBy}) async {}
  @override
  Future<void> applyReaction(String t, String u, String e) async {}
  @override
  Future<void> markRead(List<String> ids) async {}
  @override
  Future<String?> highWaterMark(String roomId) async => null;
  @override
  Future<List<SearchHit>> search(
    String query, {
    String? roomId,
    int limit = 50,
  }) async => const [];
}

class _StubStore implements AccountLocalStore {
  _StubStore(this.value);
  LocalAccount? value;
  @override
  Future<LocalAccount?> load() async => value;
  @override
  Future<void> save(LocalAccount a) async {
    value = a;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

void main() {
  // ProfileScreen (reached for the sign-out flow) embeds the wallpaper picker,
  // which reads SharedPreferences.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('null account renders the choice screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountLocalStoreProvider.overrideWithValue(_StubStore(null)),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('I have a recovery phrase'), findsOneWidget);
  });

  testWidgets('populated account renders the inbox shell', (tester) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountLocalStoreProvider.overrideWithValue(_StubStore(acc)),
          // Pretend the room list has synced so HomeScreen shows the empty
          // pairing state rather than the "still syncing" blank canvas.
          inboxSyncedProvider.overrideWith((ref) => true),
          liveConnectionProvider.overrideWith(
            (_) => Completer<LiveConnection>().future,
          ),
          pairingTransportProvider.overrideWithValue(_FakeTransport()),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();
    // HomeScreen renders the empty-rooms pairing placeholder when no rooms are
    // registered.
    expect(find.textContaining('PAIR WITH YOUR PARTNER'), findsOneWidget);
  });

  testWidgets('sign out wipes the account and returns to the choice screen', (
    tester,
  ) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026),
    );
    final store = _StubStore(acc);
    final keystore = InMemoryKeystore();
    await keystore.write('llove.master.court', 'seed');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountLocalStoreProvider.overrideWithValue(store),
          keystoreProvider.overrideWithValue(keystore),
          readStateStoreProvider.overrideWithValue(_FakeReadStateStore()),
          outboxStoreProvider.overrideWith((_) async => MemoryOutboxStore()),
          messageDbProvider.overrideWith((_) async => _FakeMessageDb()),
          // No real socket.
          liveConnectionProvider.overrideWith(
            (_) => Completer<LiveConnection>().future,
          ),
          pairingTransportProvider.overrideWithValue(_FakeTransport()),
          inboxSyncedProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('PAIR WITH YOUR PARTNER'), findsOneWidget);

    // Open the profile (top-left avatar) and sign out from there.
    await tester.tap(find.byKey(const Key('home-open-profile')));
    await tester.pumpAndSettle();
    final signOutBtn = find.byKey(const Key('profile-sign-out'));
    await tester.ensureVisible(signOutBtn);
    await tester.pumpAndSettle();
    await tester.tap(signOutBtn);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-signout')));
    await tester.pumpAndSettle();

    // The local identity is gone...
    expect(store.value, isNull);
    expect(await keystore.read('llove.master.court'), isNull);
    // ...and we're back at the signup choice screen.
    expect(find.text('Get started'), findsOneWidget);
  });
}
