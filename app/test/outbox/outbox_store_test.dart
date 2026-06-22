import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<OutboxStore> freshStore() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: SqliteOutboxStore.onCreate,
      ),
    );
    addTearDown(db.close);
    return OutboxStore.test(db);
  }

  test('enqueue then pending returns rows in created_at order', () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodies: {'k': 'ct-a'},
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 0),
    );
    await s.enqueue(
      clientMsgId: 'b',
      roomId: 'r1',
      bodies: {'k': 'ct-b'},
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 1),
    );
    final rows = await s.pending();
    expect(rows.map((r) => r.clientMsgId).toList(), ['a', 'b']);
    expect(rows.first.bodies['k'], 'ct-a');
    expect(rows.first.roomId, 'r1');
  });

  test(
    'remove deletes by client_msg_id and returns whether a row was removed',
    () async {
      final s = await freshStore();
      await s.enqueue(
        clientMsgId: 'a',
        roomId: 'r1',
        bodies: {'k': 'ct'},
        createdAt: DateTime.utc(2026, 6, 13),
      );
      expect(await s.remove('a'), isTrue);
      expect(await s.remove('a'), isFalse);
      expect((await s.pending()).isEmpty, isTrue);
    },
  );

  test('clear deletes every queued row', () async {
    final s = await freshStore();
    await s.enqueue(clientMsgId: 'a', roomId: 'r1', bodies: {'k': 'ct-a'});
    await s.enqueue(clientMsgId: 'b', roomId: 'r2', bodies: {'k': 'ct-b'});
    await s.clear();
    expect(await s.pending(), isEmpty);
  });

  test('markAttempt bumps attempts and stores last_error', () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodies: {'k': 'ct'},
      createdAt: DateTime.utc(2026, 6, 13),
    );
    await s.markAttempt('a', error: 'boom');
    await s.markAttempt('a');
    final row = (await s.pending()).single;
    expect(row.attempts, 2);
    expect(row.lastError, isNull);
  });

  test(
    'markAttempt with reset:true zeroes attempts and clears last_error',
    () async {
      final s = await freshStore();
      await s.enqueue(
        clientMsgId: 'a',
        roomId: 'r1',
        bodies: {'k': 'ct'},
        createdAt: DateTime.utc(2026, 6, 13),
      );
      await s.markAttempt('a', error: 'x');
      await s.markAttempt('a', reset: true);
      final row = (await s.pending()).single;
      expect(row.attempts, 0);
      expect(row.lastError, isNull);
    },
  );

  test('lookup returns the matching row or null', () async {
    final s = await freshStore();
    expect(await s.lookup('missing'), isNull);
    await s.enqueue(
      clientMsgId: 'a',
      roomId: 'r1',
      bodies: {'k': 'ct'},
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final row = await s.lookup('a');
    expect(row, isNotNull);
    expect(row!.roomId, 'r1');
    expect(row.bodies['k'], 'ct');
  });
}
