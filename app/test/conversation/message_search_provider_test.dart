import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_search.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<ProviderContainer> seeded() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    final messageDb = MessageDb.test(db);
    await messageDb.upsert(
      Msg(
        id: '01A',
        from: 'alice',
        to: 'room1',
        body: 'I love you',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await messageDb.upsert(
      Msg(
        id: '01B',
        from: 'alice',
        to: 'room2',
        body: 'love letters',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room2',
    );
    final container = ProviderContainer(
      overrides: [messageDbProvider.overrideWith((_) async => messageDb)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'channelSearchProvider scopes to the room; empty query → empty',
    () async {
      final container = await seeded();
      expect(
        await container.read(
          channelSearchProvider((roomId: 'room1', query: '')).future,
        ),
        isEmpty,
      );
      final hits = await container.read(
        channelSearchProvider((roomId: 'room1', query: 'love')).future,
      );
      expect(hits.map((h) => h.messageId), ['01A']);
    },
  );

  test('globalSearchProvider spans rooms; empty query → empty', () async {
    final container = await seeded();
    expect(await container.read(globalSearchProvider('').future), isEmpty);
    final hits = await container.read(globalSearchProvider('love').future);
    expect(hits.map((h) => h.messageId).toSet(), {'01A', '01B'});
  });
}
