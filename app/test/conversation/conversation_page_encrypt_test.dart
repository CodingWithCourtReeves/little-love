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
        ],
      );
      addTearDown(container.dispose);

      // Resolve async providers so requireValue works inside the send path.
      await container.read(accountProvider.future);
      await container.read(currentIdentityProvider.future);
      await container.read(liveConnectionProvider.future);

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
      // Encrypt path is async — give it time to finish before asserting.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final sendFrames = conn.sent.where((m) => m['kind'] == 'Send').toList();
      expect(sendFrames, hasLength(1));
      final body = sendFrames.single['body'] as String;
      expect(
        body,
        isNot(contains('hello')),
        reason: 'plaintext must NOT appear on the wire — spec §13 AC #3',
      );
      expect(body.length, greaterThan(0));
      expect(sendFrames.single['room_id'], 'room1');
    },
  );
}
