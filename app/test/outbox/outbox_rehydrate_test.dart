import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_content.dart';
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

  test('rehydrate decodes a file envelope into a media bubble', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final selfPub = base64.encode(me.x25519PublicKey);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-file',
      roomId: 'room1',
      bodies: {selfPub: 'ct-file'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );

    const descriptor = AttachmentDescriptor(
      blobKey: 'blob-1',
      contentKeyB64: 'k',
      nonceB64: 'n',
      mime: 'image/jpeg',
      filename: 'pic.jpg',
      size: 1234,
      width: 100,
      height: 80,
      durationMs: null,
      thumbB64: 'thumb',
    );
    final envelope = FileContent(descriptor, caption: 'hello').encode();

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
      decrypt: (room, cipher) async => envelope,
    );

    final msg = container.read(messageStoreProvider('room1')).single;
    expect(msg.sendStatus, SendStatus.sending);
    expect(msg.attachment, isNotNull);
    expect(msg.attachment!.blobKey, 'blob-1');
    expect(msg.body, 'hello', reason: 'caption becomes the bubble body');
    expect(
      msg.body.contains('blob_key'),
      isFalse,
      reason: 'the raw descriptor JSON must never leak into the bubble',
    );
  });

  test('rehydrate skips a pending reaction (not a timeline bubble)', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final selfPub = base64.encode(me.x25519PublicKey);
    final store = MemoryOutboxStore();
    await store.enqueue(
      clientMsgId: 'cli-react',
      roomId: 'room1',
      bodies: {selfPub: 'ct-react'},
      createdAt: DateTime.utc(2026, 6, 13, 9, 0),
    );
    final envelope = const ReactionContent(
      targetId: 'msg-9',
      emoji: '❤️',
    ).encode();

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
      decrypt: (room, cipher) async => envelope,
    );

    expect(
      container.read(messageStoreProvider('room1')),
      isEmpty,
      reason: 'a pending reaction drains silently; never a bubble',
    );
  });

  test(
    'rehydrate applies a pending delete as a tombstone, no bubble',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final selfPub = base64.encode(me.x25519PublicKey);
      final store = MemoryOutboxStore();
      await store.enqueue(
        clientMsgId: 'cli-del',
        roomId: 'room1',
        bodies: {selfPub: 'ct-del'},
        createdAt: DateTime.utc(2026, 6, 13, 9, 0),
      );
      final envelope = const DeleteContent(targetId: 'target-1').encode();

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Seed the soon-to-be-deleted target as if replay already added it.
      container
          .read(messageStoreProvider('room1').notifier)
          .add(
            Msg(
              id: 'target-1',
              from: 'court',
              to: 'room1',
              body: 'oops',
              ts: DateTime.utc(2026, 6, 13, 8),
            ),
          );

      await rehydrateOutbox(
        store: store,
        me: 'court',
        identity: me,
        keyCache: container.read(roomKeyCacheProvider),
        rooms: [mkRoom('room1', me, peer)],
        getMessageStore: (rid) =>
            container.read(messageStoreProvider(rid).notifier),
        decrypt: (room, cipher) async => envelope,
      );

      // The delete is not a bubble, and its target is tombstoned (removed).
      expect(container.read(messageStoreProvider('room1')), isEmpty);
    },
  );

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
