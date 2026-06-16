import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/twilight.dart';
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

void main() {
  testWidgets('renders inbound and outbound bubbles distinctly', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(inboxStateProvider.notifier).select('roomA');
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'long. miss you.',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hey love'), findsOneWidget);
    expect(find.text('long. miss you.'), findsOneWidget);
    expect(find.byKey(const Key('channel-switcher-pill')), findsOneWidget);
  });

  testWidgets('tapping send button fires onSend', (tester) async {
    String? sent;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (t) => sent = t,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 'hi');
  });
}
