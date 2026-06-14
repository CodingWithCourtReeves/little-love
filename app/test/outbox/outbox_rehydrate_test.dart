import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_rehydrate.dart';
import 'package:littlelove/wire/message.dart';

import 'memory_outbox_store.dart';

void main() {
  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  Room _mkRoom(String id, DerivedIdentity peer) => Room(
        roomId: id,
        peerUsername: 'kaitlyn',
        peerEd25519PubBase64: base64.encode(peer.ed25519PublicKey),
        peerX25519PubBase64: base64.encode(peer.x25519PublicKey),
        createdAt: DateTime.utc(2026, 6, 10),
      );

  test('rehydrate re-inserts a sending bubble per pending row', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-1',
      roomId: 'room1',
      bodyCipher: 'ct-1',
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );
    await store.enqueue(
      clientMsgId: 'cli-2',
      roomId: 'room2',
      bodyCipher: 'ct-2',
      createdAt: DateTime.utc(2026, 6, 13, 9, 1),
    );
    await store.enqueue(
      clientMsgId: 'cli-stale',
      roomId: 'gone',
      bodyCipher: 'ct-x',
      createdAt: DateTime.utc(2026, 6, 13, 9, 2),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await rehydrateOutbox(
      store: store,
      me: 'court',
      identity: me,
      keyCache: container.read(roomKeyCacheProvider),
      rooms: [_mkRoom('room1', peer), _mkRoom('room2', peer)],
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

    expect(container.read(messageStoreProvider('gone')), isEmpty,
        reason: 'stale row (room not in inbox) is skipped silently');
  });

  test('rehydrate marks row failed when decrypt throws', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-1',
      roomId: 'room1',
      bodyCipher: 'ct-broken',
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await rehydrateOutbox(
      store: store,
      me: 'court',
      identity: me,
      keyCache: container.read(roomKeyCacheProvider),
      rooms: [_mkRoom('room1', peer)],
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
