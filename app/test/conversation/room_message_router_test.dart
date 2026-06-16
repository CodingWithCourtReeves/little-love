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
import 'package:littlelove/inbox/owned_bots_provider.dart';
import 'package:littlelove/inbox/pending_invites_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/pairing/encryption.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';

import '../outbox/memory_outbox_store.dart';

class _FakeConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Object> sent = [];

  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async => _ctl.close();

  void emit(RoomServerFrame f) => _ctl.add(f);
}

Future<ProviderContainer> _container({
  required LiveConnection conn,
  required DerivedIdentity me,
  OutboxStore? outbox,
}) async {
  final container = ProviderContainer(
    overrides: [
      liveConnectionProvider.overrideWith((_) async => conn),
      currentIdentityProvider.overrideWith((_) async => me),
      if (outbox != null)
        outboxStoreProvider.overrideWith((_) async => outbox),
    ],
  );
  addTearDown(container.dispose);
  await container.read(liveConnectionProvider.future);
  await container.read(currentIdentityProvider.future);
  if (outbox != null) await container.read(outboxStoreProvider.future);
  return container;
}

Member _member(String username, DerivedIdentity id, {bool bot = false}) =>
    Member(
      username: username,
      ed25519PubBase64: base64.encode(id.ed25519PublicKey),
      x25519PubBase64: base64.encode(id.x25519PublicKey),
      isBot: bot,
    );

void main() {
  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  test('Rooms frame populates inbox + ownedBots + subscribes', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomsFrame(
        rooms: [
          RoomDetail(
            roomId: 'room1',
            name: '',
            members: [_member('court', me), _member('kaitlyn', peer)],
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ],
        ownedBots: [_member('court-garden', peer, bot: true)],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final inbox = container.read(inboxStateProvider);
    expect(inbox.rooms, hasLength(1));
    expect(inbox.rooms.single.roomId, 'room1');

    final owned = container.read(ownedBotsProvider);
    expect(owned.single.username, 'court-garden');

    final subs = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'Subscribe')
        .toList();
    expect(subs, hasLength(1));
    expect(subs.single['room_id'], 'room1');
  });

  test(
    'Message decrypts using sender pubkey and lands in messageStore',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
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
    },
  );

  test('tampered Message lands with body == cannotDecryptSentinel', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
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

  test('RoomCreated appends, surfaces pendingInvite, and subscribes', () async {
    final me = await deriveIdentity(seedA);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomCreatedFrame(
        roomId: 'room2',
        name: 'Travel',
        members: [_member('court', me)],
        pendingInvite: PendingInvite(
          code: 'amber-fern-locket-tide',
          qrPngBase64: '',
          expiresAt: DateTime.utc(2026, 6, 10, 19),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(inboxStateProvider).rooms, hasLength(1));
    expect(
      container.read(pendingInvitesProvider)['room2']?.code,
      'amber-fern-locket-tide',
    );
    final subs = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'Subscribe')
        .toList();
    expect(subs.single['room_id'], 'room2');
  });

  test('RoomRenamed updates the inbox name', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    conn.emit(const RoomRenamedFrame(roomId: 'room1', name: 'Daily life'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(inboxStateProvider).rooms.single.name, 'Daily life');
  });

  test(
    'MemberLeft drops the member; room cascades when last human leaves',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'soloBot',
          name: '',
          members: [
            _member('court', me),
            _member('court-garden', peer, bot: true),
          ],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(roomMessageRouterProvider);

      conn.emit(const MemberLeftFrame(roomId: 'soloBot', username: 'court'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Court was the only human → room cascades.
      expect(container.read(inboxStateProvider).rooms, isEmpty);
    },
  );

  test(
    'self-copy with clientMsgId reconciles the echo and drops the outbox row',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final outbox = MemoryOutboxStore();
      final selfPub = base64.encode(me.x25519PublicKey);
      await outbox.enqueue(
        clientMsgId: 'cli-1',
        roomId: 'room1',
        bodies: {selfPub: 'ignored-ciphertext'},
      );
      final container = await _container(conn: conn, me: me, outbox: outbox);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      // Optimistic echo already on screen, keyed by the clientMsgId.
      container.read(messageStoreProvider('room1').notifier).add(
            Msg(
              id: 'cli-1',
              from: 'court',
              to: 'room1',
              body: 'hi love',
              ts: DateTime.utc(2026, 6, 10, 12),
              clientMsgId: 'cli-1',
              sendStatus: SendStatus.sending,
            ),
          );
      container.read(roomMessageRouterProvider);

      // The server echoes our own self-copy: encrypted to our own pubkey
      // (ECDH of our key with itself), tagged with the originating clientMsgId.
      final key = await deriveRoomKey(
        me: me,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'srv-1',
          roomId: 'room1',
          from: 'court',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
          clientMsgId: 'cli-1',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Echo reconciled in place: id swapped to the authoritative server id.
      final msgs = container.read(messageStoreProvider('room1'));
      expect(msgs, hasLength(1));
      expect(msgs.single.id, 'srv-1');
      expect(msgs.single.body, 'hi love');

      // Outbox row dropped so the drain won't resend it.
      expect(await outbox.lookup('cli-1'), isNull);
    },
  );
}
