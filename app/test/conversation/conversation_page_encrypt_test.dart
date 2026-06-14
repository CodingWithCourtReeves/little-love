import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/screens/inbox/inbox_shell.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _CapturingConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Map<String, Object?>> sent = [];
  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) => sent.add(payload as Map<String, Object?>);
  @override
  Future<void> close() async => _ctl.close();
}

/// Pure in-memory OutboxStore. Used in widget tests to avoid sqflite_ffi's
/// background-isolate setup, which keeps Riverpod's FutureProvider overrides
/// from settling under the AutomatedTestWidgetsFlutterBinding.
class _MemoryOutboxStore implements OutboxStore {
  final Map<String, OutboxRow> _rows = {};

  @override
  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required String bodyCipher,
    DateTime? createdAt,
  }) async {
    _rows.putIfAbsent(
      clientMsgId,
      () => OutboxRow(
        clientMsgId: clientMsgId,
        roomId: roomId,
        bodyCipher: bodyCipher,
        createdAt: createdAt ?? DateTime.now().toUtc(),
        attempts: 0,
        lastError: null,
      ),
    );
  }

  @override
  Future<List<OutboxRow>> pending() async {
    final list = _rows.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<OutboxRow?> lookup(String clientMsgId) async => _rows[clientMsgId];

  @override
  Future<bool> remove(String clientMsgId) async =>
      _rows.remove(clientMsgId) != null;

  @override
  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  }) async {
    final r = _rows[clientMsgId];
    if (r == null) return;
    _rows[clientMsgId] = OutboxRow(
      clientMsgId: r.clientMsgId,
      roomId: r.roomId,
      bodyCipher: r.bodyCipher,
      createdAt: r.createdAt,
      attempts: reset ? 0 : r.attempts + 1,
      lastError: reset ? null : error,
    );
  }
}

void main() {
  testWidgets(
    'typing a message sends opaque ciphertext on the wire — plaintext never appears',
    (tester) async {
      final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _CapturingConn();
      addTearDown(conn.close);
      final store = _MemoryOutboxStore();

      final acc = LocalAccount(
        username: 'court',
        ed25519PubBase64: base64.encode(me.ed25519PublicKey),
        x25519PubBase64: base64.encode(me.x25519PublicKey),
        createdAt: DateTime.utc(2026, 6, 10),
      );

      final container = ProviderContainer(
        overrides: [
          accountProvider.overrideWith((_) async => acc),
          currentIdentityProvider.overrideWith((_) async => me),
          liveConnectionProvider.overrideWith((_) async => conn),
          outboxStoreProvider.overrideWith((_) async => store),
        ],
      );
      addTearDown(container.dispose);

      // Resolve async providers so requireValue works inside the send path.
      await container.read(accountProvider.future);
      await container.read(currentIdentityProvider.future);
      await container.read(liveConnectionProvider.future);
      await container.read(outboxStoreProvider.future);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          peerUsername: 'kaitlyn',
          peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
          peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(inboxStateProvider.notifier).select('room1');

      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: InboxShell(account: acc)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer')), 'hello');
      await tester.tap(find.byIcon(Icons.send));
      // Encrypt + enqueue + drain are async — give them time to finish.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Plaintext never lands on disk: the row in the outbox is ciphertext.
      final pending = await store.pending();
      expect(pending, hasLength(1));
      expect(
        pending.single.bodyCipher,
        isNot(contains('hello')),
        reason: 'plaintext must NOT appear in the persisted outbox',
      );
      expect(pending.single.roomId, 'room1');

      // The drain wrote the row to the wire as a Send frame.
      final sendFrames = conn.sent.where((m) => m['kind'] == 'Send').toList();
      expect(sendFrames, hasLength(1));
      final body = sendFrames.single['body'] as String;
      expect(
        body,
        isNot(contains('hello')),
        reason: 'plaintext must NOT appear on the wire — spec §13 AC #3',
      );
      expect(body, pending.single.bodyCipher);
      expect(sendFrames.single['room_id'], 'room1');
      // Server types client_msg_id as Uuid; non-UUID strings cause
      // serde_json to silently drop the entire Send frame.
      expect(
        sendFrames.single['client_msg_id'] as String,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        pending.single.clientMsgId,
        sendFrames.single['client_msg_id'],
        reason: 'outbox row id must equal the wire client_msg_id',
      );
    },
  );
}
