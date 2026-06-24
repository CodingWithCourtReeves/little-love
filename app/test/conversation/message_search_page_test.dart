import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_search_page.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete (the loading spinner would hang pumpAndSettle).
    // In-process queries resolve on microtasks that pump() can flush.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<MessageDb> seededDb() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    final mdb = MessageDb.test(db);
    await mdb.upsert(
      Msg(
        id: '01A',
        from: 'kaitlyn',
        to: 'room1',
        body: 'I love you so much',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    return mdb;
  }

  testWidgets('typing a query shows a result; tapping it pops the id', (
    tester,
  ) async {
    final mdb = await seededDb();
    final room = Room(
      roomId: 'room1',
      name: '',
      members: const [],
      createdAt: DateTime.utc(2026),
    );

    String? popped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [messageDbProvider.overrideWith((_) async => mdb)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async => popped = await Navigator.of(
                  context,
                ).push(MessageSearchPage.route(room: room, selfUsername: 'me')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(); // start push
    await tester.pump(const Duration(seconds: 1)); // finish push transition

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'love',
    );
    // Let the debounce timer fire and the search future resolve. Avoid
    // pumpAndSettle: the loading spinner animates and never settles.
    final result = find.byKey(const Key('search-result-01A'));
    for (var i = 0; i < 20 && result.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(result, findsOneWidget);

    await tester.tap(result);
    await tester.pump(); // start pop
    await tester.pump(const Duration(seconds: 1)); // finish pop transition

    expect(popped, '01A');
  });
}
