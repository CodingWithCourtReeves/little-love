import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/outbox/outbox_drain.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeSender {
  final List<Map<String, Object?>> sent = [];
  bool throwOnNext = false;
  void send(String roomId, String bodyCipher, String clientMsgId) {
    if (throwOnNext) {
      throwOnNext = false;
      throw StateError('socket closed');
    }
    sent.add({
      'room_id': roomId,
      'body_cipher': bodyCipher,
      'client_msg_id': clientMsgId,
    });
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<OutboxStore> freshStore() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options:
          OpenDatabaseOptions(version: 1, onCreate: SqliteOutboxStore.onCreate),
    );
    addTearDown(db.close);
    return OutboxStore.test(db);
  }

  test('drain sends all pending rows in created_at order', () async {
    final s = await freshStore();
    final sender = _FakeSender();
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodyCipher: 'ct-a',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 0),
    );
    await s.enqueue(
      clientMsgId: 'b',
      roomId: 'r1',
      bodyCipher: 'ct-b',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 1),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    await drain.runOnce();
    expect(sender.sent.map((m) => m['client_msg_id']).toList(), ['a', 'b']);
    // Rows are NOT removed by drain — that happens on echo.
    expect((await s.pending()).length, 2);
    expect((await s.pending()).first.attempts, 1);
  });

  test('drain stops at the first send error and records last_error',
      () async {
    final s = await freshStore();
    final sender = _FakeSender()..throwOnNext = true;
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    await drain.runOnce();
    expect(sender.sent, isEmpty);
    final row = (await s.pending()).single;
    expect(row.attempts, 1);
    expect(row.lastError, contains('socket closed'));
  });

  test('kick is idempotent — concurrent kicks coalesce', () async {
    final s = await freshStore();
    final sender = _FakeSender();
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    final f1 = drain.kick();
    final f2 = drain.kick();
    await Future.wait([f1, f2]);
    expect(sender.sent.length, 1);
  });
}
