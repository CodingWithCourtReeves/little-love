import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/wire/message.dart';
import 'package:path/path.dart' as p;
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

  // ids sort lexicographically; later letters = newer (matches ULID ordering).
  Msg m(String id, String body, {String room = 'room1'}) => Msg(
    id: id,
    from: 'alice',
    to: room,
    body: body,
    ts: DateTime.utc(2026, 1, 1, 0, id.codeUnitAt(id.length - 1)),
  );

  test('empty / whitespace query returns nothing', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'hello world'), roomId: 'room1');
    expect(await db.search(''), isEmpty);
    expect(await db.search('   '), isEmpty);
  });

  test('prefix match finds partial words', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'I love you'), roomId: 'room1');
    final hits = await db.search('lov');
    expect(hits.map((h) => h.messageId), contains('01A'));
  });

  test('accent-insensitive', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'café tonight'), roomId: 'room1');
    expect((await db.search('cafe')).length, 1);
  });

  test('roomId scopes the search; null searches globally', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'shared word', room: 'room1'), roomId: 'room1');
    await db.upsert(m('01B', 'shared word', room: 'room2'), roomId: 'room2');
    expect((await db.search('shared', roomId: 'room1')).length, 1);
    expect((await db.search('shared')).length, 2);
  });

  test('soft-deleted messages drop out of the index', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'secret plan'), roomId: 'room1');
    await db.applyDelete('01A', requestedBy: 'alice');
    expect(await db.search('secret'), isEmpty);
  });

  test('reconciled body is searchable under the server id', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: 'cmid-1',
        from: 'alice',
        to: 'room1',
        body: 'anniversary dinner',
        ts: DateTime.utc(2026),
        clientMsgId: 'cmid-1',
        sendStatus: SendStatus.sending,
      ),
      roomId: 'room1',
    );
    await db.reconcile(
      'cmid-1',
      Msg(
        id: '01SRV',
        from: 'alice',
        to: 'room1',
        body: 'anniversary dinner',
        ts: DateTime.utc(2026),
      ),
    );
    final hits = await db.search('anniversary');
    expect(hits.single.messageId, '01SRV');
  });

  test('snippet wraps matches in <b> tags', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'happy birthday darling'), roomId: 'room1');
    final hit = (await db.search('birthday')).single;
    expect(hit.snippetHtml, contains('<b>birthday</b>'));
  });

  // The phones already hold a v1 store from the Milestone-1 build, so the
  // search build runs onUpgrade 1->2. Prove that path creates the FTS index and
  // backfills the existing rows, so search isn't empty after the upgrade.
  test(
    'v1 -> v2 upgrade creates the index and backfills existing rows',
    () async {
      // A real file path so the v1 store persists across the reopen at v2
      // (:memory: would hand back a fresh empty db each open).
      final dir = await Directory.systemTemp.createTemp('msgdb_migrate');
      addTearDown(() => dir.delete(recursive: true));
      final dbPath = p.join(dir.path, 'messages.db');
      // Open at v1: the pre-search schema (no FTS table/triggers).
      final v1 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE messages (
              id TEXT NOT NULL, room_id TEXT NOT NULL, from_user TEXT NOT NULL,
              body TEXT NOT NULL, ts INTEGER NOT NULL, send_status INTEGER NOT NULL,
              client_msg_id TEXT, attachment TEXT, link_preview TEXT,
              call_outcome TEXT, reactions TEXT NOT NULL DEFAULT '{}',
              deleted INTEGER NOT NULL DEFAULT 0, deleted_by TEXT,
              PRIMARY KEY (id)
            )
          ''');
            await db.execute(
              'CREATE INDEX messages_room_id_idx ON messages(room_id, id)',
            );
            await db.execute(
              'CREATE TABLE room_sync (room_id TEXT PRIMARY KEY, hwm TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE tombstones (target_id TEXT PRIMARY KEY, '
              'requested_by TEXT NOT NULL)',
            );
          },
        ),
      );
      await v1.insert('messages', {
        'id': '01OLD',
        'room_id': 'room1',
        'from_user': 'alice',
        'body': 'legacy memories',
        'ts': 0,
        'send_status': SendStatus.sent.index,
        'reactions': '{}',
        'deleted': 0,
      });
      await v1.close();

      // Reopen at v2: onUpgrade builds + backfills the FTS index.
      final v2 = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: MessageDb.schemaVersion,
          onCreate: MessageDb.onCreate,
          onUpgrade: MessageDb.onUpgrade,
        ),
      );
      addTearDown(v2.close);
      final db = MessageDb.test(v2);
      final hits = await db.search('legacy');
      expect(hits.single.messageId, '01OLD');
    },
  );
}
