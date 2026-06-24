import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/global_search_page.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate: queries resolve on microtasks under the fake-async clock.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Member member(String u) =>
      Member(username: u, ed25519PubBase64: '', x25519PubBase64: '');

  testWidgets('groups results by room; tapping a hit opens that room+message', (
    tester,
  ) async {
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
        body: 'love note',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await mdb.upsert(
      Msg(
        id: '01B',
        from: 'kaitlyn',
        to: 'room2',
        body: 'love song',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room2',
    );

    final container = ProviderContainer(
      overrides: [
        messageDbProvider.overrideWith((_) async => mdb),
        accountProvider.overrideWith(
          (_) async => LocalAccount(
            username: 'me',
            ed25519PubBase64: 'A',
            x25519PubBase64: 'B',
            createdAt: DateTime.utc(2026),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Daily',
        members: [member('me'), member('kaitlyn')],
        createdAt: DateTime.utc(2026),
      ),
      Room(
        roomId: 'room2',
        name: 'Trips',
        members: [member('me'), member('kaitlyn')],
        createdAt: DateTime.utc(2026),
      ),
    ]);

    String? openedRoom;
    String? openedMsg;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: GlobalSearchPage(
            onOpen: (r, m) {
              openedRoom = r;
              openedMsg = m;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('global-search-field')),
      'love',
    );
    final res = find.byKey(const Key('global-result-01A'));
    for (var i = 0; i < 20 && res.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Both rooms' hits show, grouped under their room-name headers.
    expect(res, findsOneWidget);
    expect(find.byKey(const Key('global-result-01B')), findsOneWidget);
    expect(find.text('Daily'), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);

    await tester.tap(res);
    await tester.pump();
    expect(openedRoom, 'room1');
    expect(openedMsg, '01A');
  });
}
