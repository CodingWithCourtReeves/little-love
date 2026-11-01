import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/select_room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';

class _FakeConn implements LiveConnection {
  final List<Object> sent = [];
  @override
  Stream<RoomServerFrame> get incoming => const Stream.empty();
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async {}
}

Msg _msg(String id) => Msg(
  id: id,
  from: 'kaitlyn',
  to: 'room1',
  body: 'x',
  ts: DateTime.utc(2026, 6, 10, 12),
);

Future<ProviderContainer> _container(LiveConnection conn) async {
  final container = ProviderContainer(
    overrides: [liveConnectionProvider.overrideWith((_) async => conn)],
  );
  addTearDown(container.dispose);
  await container.read(liveConnectionProvider.future);
  return container;
}

void main() {
  test('sendMarkRead sends MarkRead with the highest message id', () async {
    final conn = _FakeConn();
    final container = await _container(conn);
    final store = container.read(messageStoreProvider('room1').notifier);
    store.add(_msg('01JA'));
    store.add(_msg('01JC'));
    store.add(_msg('01JB'));

    sendMarkRead(container, 'room1');

    final marks = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'MarkRead')
        .toList();
    expect(marks, hasLength(1));
    expect(marks.single['room_id'], 'room1');
    expect(marks.single['up_to_message_id'], '01JC');
  });

  test(
    'the watermark still covers a newest message I deleted for me',
    () async {
      final conn = _FakeConn();
      final container = await _container(conn);
      final store = container.read(messageStoreProvider('room1').notifier);
      store.add(_msg('01JA'));
      store.add(_msg('01JC'));
      store.deleteForMe('01JC');
      // Ids deleted in another room (seeded on hydrate) must not raise this
      // room's watermark past messages not yet seen here.
      store.seedDeletedForMe(['01JZ']);

      sendMarkRead(container, 'room1');

      final marks = conn.sent
          .cast<Map<String, Object?>>()
          .where((m) => m['kind'] == 'MarkRead')
          .toList();
      expect(marks.single['up_to_message_id'], '01JC');
    },
  );

  test('deleting the only message for me still marks it read', () async {
    final conn = _FakeConn();
    final container = await _container(conn);
    final store = container.read(messageStoreProvider('room1').notifier);
    store.add(_msg('01JA'));
    store.deleteForMe('01JA');

    sendMarkRead(container, 'room1');

    final marks = conn.sent.cast<Map<String, Object?>>().toList();
    expect(marks.single['up_to_message_id'], '01JA');
  });

  test('sendMarkRead is a no-op when the room has no messages', () async {
    final conn = _FakeConn();
    final container = await _container(conn);

    sendMarkRead(container, 'emptyRoom');

    expect(conn.sent, isEmpty);
  });
}
