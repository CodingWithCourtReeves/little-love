import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

import '../support/test_read_state.dart';

Room _room(String id, String name) => Room(
  roomId: id,
  name: name,
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

Msg _m(String id, String body, String from) => Msg(
  id: id,
  from: from,
  to: 'court',
  body: body,
  ts: DateTime.utc(2026, 6, 9, 17),
);

void main() {
  testWidgets('messages in room A do not appear in room B view', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        hermeticReadStateStore(),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(messageStoreProvider('roomA').notifier)
        .add(_m('a1', 'in A', 'kaitlyn'));
    container
        .read(messageStoreProvider('roomB').notifier)
        .add(_m('b1', 'in B', 'sage'));

    Widget showRoom(String id, String name) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _room(id, name),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      );
    }

    await tester.pumpWidget(showRoom('roomA', 'Kaitlyn'));
    await tester.pumpAndSettle();
    expect(find.text('in A'), findsOneWidget);
    expect(find.text('in B'), findsNothing);

    await tester.pumpWidget(showRoom('roomB', 'Sage'));
    await tester.pumpAndSettle();
    expect(find.text('in B'), findsOneWidget);
    expect(find.text('in A'), findsNothing);

    // Add a new message to room A while room B is the active view; the
    // room B view stays unchanged.
    container
        .read(messageStoreProvider('roomA').notifier)
        .add(_m('a2', 'later in A', 'kaitlyn'));
    await tester.pump();
    expect(find.text('later in A'), findsNothing);
  });
}
