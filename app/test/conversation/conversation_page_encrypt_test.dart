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

import '../outbox/memory_outbox_store.dart';

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
      final store = MemoryOutboxStore();

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
          name: '',
          members: [
            Member(
              username: 'court',
              ed25519PubBase64: base64.encode(me.ed25519PublicKey),
              x25519PubBase64: base64.encode(me.x25519PublicKey),
              isBot: false,
            ),
            Member(
              username: 'kaitlyn',
              ed25519PubBase64: base64.encode(peer.ed25519PublicKey),
              x25519PubBase64: base64.encode(peer.x25519PublicKey),
              isBot: false,
            ),
          ],
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

      // Plaintext never lands on disk: every persisted body is ciphertext.
      final pending = await store.pending();
      expect(pending, hasLength(1));
      for (final body in pending.single.bodies.values) {
        expect(
          body,
          isNot(contains('hello')),
          reason: 'plaintext must NOT appear in the persisted outbox',
        );
      }
      expect(pending.single.roomId, 'room1');

      // The drain wrote the row to the wire as a Send frame.
      final sendFrames = conn.sent.where((m) => m['kind'] == 'Send').toList();
      expect(sendFrames, hasLength(1));
      final bodies = sendFrames.single['bodies'] as Map<String, Object?>;
      // One addressed ciphertext per other room member (kaitlyn) plus a
      // copy addressed to ourselves so the server persists it for us too.
      expect(bodies.length, 2);
      expect(bodies.keys.toSet(), {
        base64.encode(peer.x25519PublicKey),
        base64.encode(me.x25519PublicKey),
      });
      for (final body in bodies.values.cast<String>()) {
        expect(
          body,
          isNot(contains('hello')),
          reason: 'plaintext must NOT appear on the wire — spec §13 AC #3',
        );
        expect(body.length, greaterThan(0));
      }
      // What we persisted is exactly what went to the wire.
      expect(bodies, pending.single.bodies);
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
