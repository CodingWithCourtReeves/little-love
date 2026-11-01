import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/inbox/room_removal.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/profile/profile_publish_cache.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../outbox/memory_outbox_store.dart';
import '../support/test_read_state.dart';

/// Hands a test the container's own [Ref], the type the router passes in.
final _refProvider = Provider<Ref>((ref) => ref);

Room _room(String id, String name) => Room(
  roomId: id,
  name: name,
  members: const [
    Member(username: 'court', ed25519PubBase64: 'a', x25519PubBase64: 'b'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'c', x25519PubBase64: 'd'),
  ],
  createdAt: DateTime.utc(2026),
);

Msg _msg(String id, String room) =>
    Msg(id: id, from: 'kaitlyn', to: room, body: 'hi', ts: DateTime.utc(2026));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(ProviderContainer, MessageDb, MemoryOutboxStore)> setup() async {
    SharedPreferences.setMockInitialValues({});
    final raw = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(raw.close);
    final db = MessageDb.test(raw);
    final outbox = MemoryOutboxStore();
    final container = ProviderContainer(
      overrides: [
        messageDbProvider.overrideWith((_) async => db),
        outboxStoreProvider.overrideWith((_) async => outbox),
        hermeticReadStateStore(),
      ],
    );
    addTearDown(container.dispose);
    return (container, db, outbox);
  }

  test('purgeRoomLocally clears the room\'s messages, outbox rows, read state '
      'and store, and nothing of any other room', () async {
    final (container, db, outbox) = await setup();
    for (final room in ['room1', 'room2']) {
      await db.upsert(_msg('01$room', room), roomId: room);
      await outbox.enqueue(clientMsgId: 'cm-$room', roomId: room, bodies: {});
      container.read(readStateProvider.notifier).markRead(room);
      container
          .read(messageStoreProvider(room).notifier)
          .add(_msg('01$room', room));
    }
    const avatar = AttachmentDescriptor(
      blobKey: 'avatar',
      contentKeyB64: 'k',
      nonceB64: 'n',
      mime: 'image/jpeg',
      filename: 'avatar.jpg',
      size: 1,
      width: 1,
      height: 1,
      durationMs: null,
      thumbB64: '',
    );
    await container
        .read(profilePublishCacheProvider)
        .setAvatar(avatar, 'avatar');

    await purgeRoomLocally(container.read(_refProvider), 'room1');

    expect(await db.messagesFor('room1'), isEmpty);
    expect((await db.messagesFor('room2')).single.id, '01room2');
    expect((await outbox.pending()).map((r) => r.clientMsgId), ['cm-room2']);
    expect(container.read(readStateProvider).keys, ['room2']);
    expect(container.read(messageStoreProvider('room1')), isEmpty);
    expect(container.read(messageStoreProvider('room2')), hasLength(1));
    // The avatar may have been uploaded into the deleted room; forget it so
    // the next publish re-uploads into a room that still exists.
    expect(await container.read(profilePublishCacheProvider).avatar(), isNull);
  });

  test('hideRoom drops the inbox row and keeps the others', () async {
    final (container, _, _) = await setup();
    container.read(inboxStateProvider.notifier).setRooms([
      _room('room1', 'Travel'),
      _room('room2', ''),
    ]);

    hideRoom(container.read(_refProvider), 'room1');

    expect(container.read(inboxStateProvider).rooms.map((r) => r.roomId), [
      'room2',
    ]);
  });
}
