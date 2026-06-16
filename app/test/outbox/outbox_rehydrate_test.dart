import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_rehydrate.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

import 'memory_outbox_store.dart';

void main() {
  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  Member member(String username, DerivedIdentity id) => Member(
    username: username,
    ed25519PubBase64: base64.encode(id.ed25519PublicKey),
    x25519PubBase64: base64.encode(id.x25519PublicKey),
  );

  Room mkRoom(String id, DerivedIdentity me, DerivedIdentity peer) => Room(
    roomId: id,
    name: '',
    members: [member('court', me), member('kaitlyn', peer)],
    createdAt: DateTime.utc(2026, 6, 10),
  );

  test('rehydrate re-inserts a sending bubble per pending row', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final selfPub = base64.encode(me.x25519PublicKey);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-1',
      roomId: 'room1',
      bodies: {selfPub: 'ct-1'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );
    await store.enqueue(
      clientMsgId: 'cli-2',
      roomId: 'room2',
      bodies: {selfPub: 'ct-2'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 1),
    );
    await store.enqueue(
      clientMsgId: 'cli-stale',
      roomId: 'gone',
      bodies: {selfPub: 'ct-x'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 2),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await rehydrateOutbox(
      store: store,
      me: 'court',
      identity: me,
      keyCache: container.read(roomKeyCacheProvider),
      rooms: [mkRoom('room1', me, peer), mkRoom('room2', me, peer)],
      getMessageStore: (rid) =>
          container.read(messageStoreProvider(rid).notifier),
      decrypt: (room, cipher) async => 'plain($cipher)',
    );

    final r1 = container.read(messageStoreProvider('room1'));
    expect(r1, hasLength(1));
    expect(r1.single.id, 'cli-1');
    expect(r1.single.body, 'plain(ct-1)');
    expect(r1.single.sendStatus, SendStatus.sending);
    expect(r1.single.from, 'court');

    final r2 = container.read(messageStoreProvider('room2'));
    expect(r2.single.body, 'plain(ct-2)');

    expect(
      container.read(messageStoreProvider('gone')),
      isEmpty,
      reason: 'stale row (room not in inbox) is skipped silently',
    );
  });

  test('rehydrate marks row failed when decrypt throws', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final selfPub = base64.encode(me.x25519PublicKey);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-1',
      roomId: 'room1',
      bodies: {selfPub: 'ct-broken'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await rehydrateOutbox(
      store: store,
      me: 'court',
      identity: me,
      keyCache: container.read(roomKeyCacheProvider),
      rooms: [mkRoom('room1', me, peer)],
      getMessageStore: (rid) =>
          container.read(messageStoreProvider(rid).notifier),
      decrypt: (room, cipher) async => throw StateError('bad key'),
    );

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs.single.sendStatus, SendStatus.failed);

    final row = await store.lookup('cli-1');
    expect(row, isNotNull);
    expect(row!.lastError, 'decrypt-failed');
  });
}
