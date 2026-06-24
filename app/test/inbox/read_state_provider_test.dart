import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Msg msg(String id, DateTime ts) =>
    Msg(id: id, from: 'kaitlyn', to: 'room-a', body: 'hi', ts: ts);

Member member(String u) =>
    Member(username: u, ed25519PubBase64: '', x25519PubBase64: '');

Room roomFor(String id) => Room(
  roomId: id,
  name: id,
  members: [member('court'), member('kaitlyn')],
  createdAt: DateTime.utc(2026, 6, 14),
);

ProviderContainer makeContainer() {
  final tmp = Directory.systemTemp.createTempSync('rsp_test');
  return ProviderContainer(
    overrides: [
      readStateStoreProvider.overrideWithValue(
        ReadStateStore(homeDirectory: tmp),
      ),
    ],
  );
}

void main() {
  test('a room with no messages is not unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });

  test('newest message after last-read marks the room unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c
        .read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });

  test('marking read clears unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c
        .read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    c
        .read(readStateProvider.notifier)
        .markRead('room-a', at: DateTime.utc(2026, 6, 14, 12));
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });

  test('a newer message after marking read re-marks unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    // Activate the provider so it tracks its dependencies and re-evaluates
    // when messageStoreProvider or readStateProvider changes.
    c.listen(roomUnreadProvider('room-a'), (_, _) {});
    final store = c.read(messageStoreProvider('room-a').notifier);
    store.add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    c
        .read(readStateProvider.notifier)
        .markRead('room-a', at: DateTime.utc(2026, 6, 14, 12));
    store.add(msg('m2', DateTime.utc(2026, 6, 14, 13)));
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });

  test('anyUnread is false when no room is unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([
      roomFor('room-a'),
      roomFor('room-b'),
    ]);
    expect(c.read(anyUnreadProvider('room-a')), isFalse);
  });

  test('anyUnread is true when another (non-excluded) room is unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([
      roomFor('room-a'),
      roomFor('room-b'),
    ]);
    c
        .read(messageStoreProvider('room-b').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    // Excluding the selected room-a, room-b is unread → dot should show.
    expect(c.read(anyUnreadProvider('room-a')), isTrue);
  });

  test('anyUnread ignores unread in the excluded room itself', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([
      roomFor('room-a'),
      roomFor('room-b'),
    ]);
    // Only the excluded room is unread → nothing "elsewhere".
    c
        .read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    expect(c.read(anyUnreadProvider('room-a')), isFalse);
  });

  test('unreadElsewhere counts other rooms, excluding the current one', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([
      roomFor('room-a'),
      roomFor('room-b'),
    ]);
    const key = (me: 'court', roomId: 'room-a');
    // Activate so the provider tracks its dependencies.
    c.listen(unreadElsewhereCountProvider(key), (_, _) {});
    c
        .read(messageStoreProvider('room-a').notifier)
        .add(msg('a1', DateTime.utc(2026, 6, 14, 12)));
    c
        .read(messageStoreProvider('room-b').notifier)
        .add(msg('b1', DateTime.utc(2026, 6, 14, 12)));
    // room-a is the current thread (excluded); only room-b's unread counts.
    expect(c.read(unreadElsewhereCountProvider(key)), 1);
  });

  test('unreadElsewhere ignores my own messages', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(inboxStateProvider.notifier).setRooms([
      roomFor('room-a'),
      roomFor('room-b'),
    ]);
    const key = (me: 'court', roomId: 'room-a');
    c.listen(unreadElsewhereCountProvider(key), (_, _) {});
    c
        .read(messageStoreProvider('room-b').notifier)
        .add(
          Msg(
            id: 'mine',
            from: 'court',
            to: 'room-b',
            body: 'hi',
            ts: DateTime.utc(2026, 6, 14, 12),
          ),
        );
    expect(c.read(unreadElsewhereCountProvider(key)), 0);
  });
}
