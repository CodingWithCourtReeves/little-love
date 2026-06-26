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
  homeDirectory: Directory.systemTemp.createTempSync('conv_scrim_rs'),
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
          onSend: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('top scrim frosts (BackdropFilter) and is pointer-transparent', (
    tester,
  ) async {
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

    // The top scrim exists, frosts (contains BackdropFilters), and is wrapped
    // in an IgnorePointer so taps pass through to the message list — i.e. it is
    // no longer the old flat gradient.
    final scrim = find.byKey(const Key('top-scrim'));
    expect(scrim, findsOneWidget);
    expect(
      find.descendant(of: scrim, matching: find.byType(BackdropFilter)),
      findsWidgets,
    );
    expect(
      find.descendant(of: scrim, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );

    // A single blur band (backdrop blur is GPU-costly on iOS — one pass, the
    // gradient carries the fade), isolated in a RepaintBoundary so unrelated
    // repaints don't force it to re-composite.
    final blurs = tester
        .widgetList<BackdropFilter>(
          find.descendant(of: scrim, matching: find.byType(BackdropFilter)),
        )
        .toList();
    expect(blurs.length, 1);
    expect(
      find.descendant(of: scrim, matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
  });
}
