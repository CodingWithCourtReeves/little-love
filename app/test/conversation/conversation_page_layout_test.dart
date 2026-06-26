import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Room _roomA() => Room(
  roomId: 'roomA',
  name: 'Kaitlyn',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 9),
);

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 9),
);

final _readStateStore = ReadStateStore(
  homeDirectory: Directory.systemTemp.createTempSync('conv_layout_rs'),
);

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: ConversationPage(
          room: _roomA(),
          selfUsername: 'court',
          onSend: (_, __) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'body is a Column with an Expanded message region above the composer',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          accountProvider.overrideWith((_) async => _account),
          httpClientProvider.overrideWithValue(http.Client()),
          readStateStoreProvider.overrideWithValue(_readStateStore),
        ],
      );
      addTearDown(container.dispose);
      container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        Msg(
          id: '1',
          from: 'kaitlyn',
          to: 'court',
          body: 'hi',
          ts: DateTime.utc(2026, 6, 9, 17, 3),
        ),
      ]);

      await _pump(tester, container);

      // The composer field and the message list both render...
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);

      // ...and the message list sits in an Expanded inside a Column (push-down
      // layout), not in a full-bleed Stack behind a floating composer.
      final listView = find.byType(ListView);
      expect(listView, findsOneWidget);
      expect(
        find.ancestor(of: listView, matching: find.byType(Expanded)),
        findsOneWidget,
      );
    },
  );

  testWidgets('composer field caps at 10 lines', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    await _pump(tester, container);

    final field = tester.widget<TextField>(find.byKey(const Key('composer')));
    expect(field.maxLines, 10);
  });
}
