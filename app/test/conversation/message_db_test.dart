import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MessageDb> freshDb() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    return MessageDb.test(db);
  }

  Msg msg(String id, {String body = 'hello', String from = 'alice'}) => Msg(
    id: id,
    from: from,
    to: 'room1',
    body: body,
    ts: DateTime.utc(2026, 6, 24, 12),
  );

  test('upsert then read back, ordered by id ascending', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'first'), roomId: 'room1');
    await db.upsert(msg('01B', body: 'second'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.map((m) => m.body), ['first', 'second']);
  });

  test('upsert is idempotent on id', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'v1'), roomId: 'room1');
    await db.upsert(msg('01A', body: 'v2'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.length, 1);
  });

  test('messagesFor scopes by room', () async {
    final db = await freshDb();
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room2');
    expect((await db.messagesFor('room1')).length, 1);
    expect((await db.messagesFor('room2')).length, 1);
  });
}
