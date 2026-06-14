import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/wire/message.dart';

Msg msg(String id, DateTime ts) =>
    Msg(id: id, from: 'kaitlyn', to: 'room-a', body: 'hi', ts: ts);

ProviderContainer makeContainer() {
  final tmp = Directory.systemTemp.createTempSync('rsp_test');
  return ProviderContainer(overrides: [
    readStateStoreProvider.overrideWithValue(
      ReadStateStore(homeDirectory: tmp),
    ),
  ]);
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
    c.read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });

  test('marking read clears unread', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('room-a').notifier)
        .add(msg('m1', DateTime.utc(2026, 6, 14, 12)));
    c.read(readStateProvider.notifier)
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
    c.read(readStateProvider.notifier)
        .markRead('room-a', at: DateTime.utc(2026, 6, 14, 12));
    store.add(msg('m2', DateTime.utc(2026, 6, 14, 13)));
    expect(c.read(roomUnreadProvider('room-a')), isTrue);
  });
}
