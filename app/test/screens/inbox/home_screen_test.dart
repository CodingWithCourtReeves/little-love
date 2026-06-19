import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/screens/inbox/home_screen.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

LocalAccount _acct() => LocalAccount(
  username: 'court',
  ed25519PubBase64: 'e',
  x25519PubBase64: 'x',
  createdAt: DateTime.utc(2026, 6, 10),
);

Room _partnerRoom(String id) => Room(
  roomId: id,
  name: '',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'e2', x25519PubBase64: 'x2'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

Widget _app(ProviderContainer c, LocalAccount acct) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: HomeScreen(account: acct)),
    );

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      // The router/drain watch the live connection; keep it perpetually
      // pending so HomeScreen mounts without a real socket.
      liveConnectionProvider.overrideWith(
        (_) => Completer<LiveConnection>().future,
      ),
      accountProvider.overrideWith((_) async => _acct()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('empty inbox shows the pairing affordance', (tester) async {
    final c = _container();
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    expect(find.text('Invite your partner'), findsOneWidget);
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets(
    'two rooms: list renders, tapping a row pushes ConversationPage, back pops',
    (tester) async {
      final c = _container();
      c.read(inboxStateProvider.notifier).setRooms([
        _partnerRoom('room1'),
        Room(
          roomId: 'room2',
          name: 'Travel',
          members: _partnerRoom('room2').members,
          createdAt: DateTime.utc(2026, 6, 11),
        ),
      ]);
      await tester.pumpWidget(_app(c, _acct()));
      await tester.pump();

      // List home, no chat pushed yet (2 rooms => no auto-open).
      expect(find.byType(ConversationPage), findsNothing);
      expect(find.text('Travel'), findsOneWidget);

      await tester.tap(find.text('Travel'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationPage), findsOneWidget);

      // Back pops to the list.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ConversationPage), findsNothing);
      expect(find.text('Travel'), findsOneWidget);
    },
  );

  testWidgets('a requested room (notification tap) pushes its conversation', (
    tester,
  ) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([
      _partnerRoom('room1'),
      Room(
        roomId: 'room2',
        name: 'Travel',
        members: _partnerRoom('room2').members,
        createdAt: DateTime.utc(2026, 6, 11),
      ),
    ]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    expect(find.byType(ConversationPage), findsNothing);

    // A notification tap sets the requested-room command signal.
    c.read(requestedRoomProvider.notifier).state = 'room2';
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);
    // The command signal is consumed, not left latched.
    expect(c.read(requestedRoomProvider), isNull);
  });

  testWidgets('single room auto-opens into the conversation', (tester) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([_partnerRoom('room1')]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);

    // Back lands on Home (the list), not a dead end.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
  });
}
