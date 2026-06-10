import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/room_message_router.dart';
import 'package:littlelove/crypto/ecdh.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/pairing/encryption.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Object> sent = [];

  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> close() async => _ctl.close();

  void emit(RoomServerFrame f) => _ctl.add(f);
}

Future<ProviderContainer> _container({
  required LiveConnection conn,
  required DerivedIdentity me,
}) async {
  final container = ProviderContainer(
    overrides: [
      liveConnectionProvider.overrideWith((_) async => conn),
      currentIdentityProvider.overrideWith((_) async => me),
    ],
  );
  addTearDown(container.dispose);
  // Resolve the async overrides so requireValue works.
  await container.read(liveConnectionProvider.future);
  await container.read(currentIdentityProvider.future);
  return container;
}

void main() {
  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  test('Rooms frame populates inboxStateProvider', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomsFrame(
        rooms: [
          RoomFramePeer(
            roomId: 'room1',
            peerUsername: 'kaitlyn',
            peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
            peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final inbox = container.read(inboxStateProvider);
    expect(inbox.rooms, hasLength(1));
    expect(inbox.rooms.single.roomId, 'room1');

    // Router auto-subscribed.
    final subs = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'Subscribe')
        .toList();
    expect(subs, hasLength(1));
    expect(subs.single['room_id'], 'room1');
  });

  test('Message frame decrypts and lands in messageStore', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container
        .read(inboxStateProvider.notifier)
        .setRooms([
          Room(
            roomId: 'room1',
            peerUsername: 'kaitlyn',
            peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
            peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ]);
    container.read(roomMessageRouterProvider);

    // Encrypt as the peer would (their priv + my pub → same shared secret).
    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.body, 'hi love');
  });

  test('tampered Message lands with body == cannotDecryptSentinel', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container
        .read(inboxStateProvider.notifier)
        .setRooms([
          Room(
            roomId: 'room1',
            peerUsername: 'kaitlyn',
            peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
            peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ]);
    container.read(roomMessageRouterProvider);

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: 'not-a-valid-ciphertext',
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.body, cannotDecryptSentinel);
  });

  test('RoomCreated appends and subscribes', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomCreatedFrame(
        RoomFramePeer(
          roomId: 'room2',
          peerUsername: 'kaitlyn',
          peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
          peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(inboxStateProvider).rooms, hasLength(1));
    final subs = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'Subscribe')
        .toList();
    expect(subs.single['room_id'], 'room2');
  });
}
