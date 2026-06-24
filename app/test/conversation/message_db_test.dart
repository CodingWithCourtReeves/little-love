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

  test('reconcile swaps the optimistic row for the server id, keeping '
      'clientMsgId', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: 'cmid-1',
        from: 'alice',
        to: 'room1',
        body: 'hi',
        ts: DateTime.utc(2026),
        clientMsgId: 'cmid-1',
        sendStatus: SendStatus.sending,
      ),
      roomId: 'room1',
    );
    await db.reconcile(
      'cmid-1',
      Msg(
        id: '01SERVER',
        from: 'alice',
        to: 'room1',
        body: 'hi',
        ts: DateTime.utc(2026),
      ),
    );
    final rows = await db.messagesFor('room1');
    expect(rows.single.id, '01SERVER');
    expect(rows.single.clientMsgId, 'cmid-1');
  });

  test('applyDelete soft-deletes and stays sticky for an out-of-order '
      'target', () async {
    final db = await freshDb();
    // Delete arrives first (target not yet stored).
    await db.applyDelete('01X', requestedBy: 'alice');
    // Target arrives later, authored by alice — must stay suppressed.
    await db.upsert(
      Msg(
        id: '01X',
        from: 'alice',
        to: 'room1',
        body: 'gone',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    expect(await db.messagesFor('room1'), isEmpty);
  });

  test(
    'applyDelete rejects a spoofed delete (requestedBy != author)',
    () async {
      final db = await freshDb();
      await db.upsert(
        Msg(
          id: '01Y',
          from: 'alice',
          to: 'room1',
          body: 'mine',
          ts: DateTime.utc(2026),
        ),
        roomId: 'room1',
      );
      await db.applyDelete(
        '01Y',
        requestedBy: 'bob',
      ); // bob can't unsend alice's
      expect((await db.messagesFor('room1')).length, 1);
    },
  );

  test('markRead promotes send_status to read', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01Z',
        from: 'me',
        to: 'room1',
        body: 'seen?',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await db.markRead(['01Z']);
    expect((await db.messagesFor('room1')).single.sendStatus, SendStatus.read);
  });

  test('applyReaction stores and toggles off', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01R',
        from: 'alice',
        to: 'room1',
        body: 'react me',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await db.applyReaction('01R', 'bob', '❤️');
    expect((await db.messagesFor('room1')).single.reactions, {'bob': '❤️'});
    await db.applyReaction('01R', 'bob', '');
    expect((await db.messagesFor('room1')).single.reactions, isEmpty);
  });

  test('highWaterMark returns the max stored id per room, null when '
      'empty', () async {
    final db = await freshDb();
    expect(await db.highWaterMark('room1'), isNull);
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01C'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room1');
    expect(await db.highWaterMark('room1'), '01C');
  });
}
