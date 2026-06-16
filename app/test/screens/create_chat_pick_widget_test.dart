import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/owned_bots_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/screens/create_chat/create_chat_pick_screen.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeConn implements LiveConnection {
  final List<Object> sent = [];
  @override
  Stream<RoomServerFrame> get incoming => const Stream<RoomServerFrame>.empty();
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> close() async {}
}

Future<ProviderContainer> _container({required _FakeConn conn}) async {
  final c = ProviderContainer(
    overrides: [liveConnectionProvider.overrideWith((_) async => conn)],
  );
  addTearDown(c.dispose);
  await c.read(liveConnectionProvider.future);
  return c;
}

Room _coupleRoom() => Room(
  roomId: 'r1',
  name: '',
  members: const [
    Member(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      isBot: false,
    ),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCCC',
      x25519PubBase64: 'DDDD',
      isBot: false,
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  testWidgets('partner toggle + Create chat emits CreateRoomFrame', (
    tester,
  ) async {
    final conn = _FakeConn();
    final container = await _container(conn: conn);
    container.read(inboxStateProvider.notifier).setRooms([_coupleRoom()]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: CreateChatPickScreen(selfUsername: 'court'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Partner row is visible.
    expect(find.byKey(const Key('partner-row')), findsOneWidget);
    // Toggle partner on.
    await tester.tap(find.byKey(const Key('partner-row')));
    await tester.pumpAndSettle();

    // Submit.
    await tester.ensureVisible(find.byKey(const Key('create-chat-button')));
    await tester.tap(find.byKey(const Key('create-chat-button')));
    await tester.pumpAndSettle();

    expect(conn.sent, hasLength(1));
    final payload = conn.sent.single as Map<String, Object?>;
    expect(payload['kind'], 'CreateRoom');
    expect(payload['invite_human_partner'], true);
    expect(payload['bot_account_ids'], isEmpty);
  });

  testWidgets('renders one familiar row per ownedBots entry', (tester) async {
    final conn = _FakeConn();
    final container = await _container(conn: conn);
    container.read(ownedBotsProvider.notifier).set(const [
      Member(
        username: 'court-garden',
        ed25519PubBase64: 'GGGG',
        x25519PubBase64: 'HHHH',
        isBot: true,
        ownerUsername: 'court',
      ),
      Member(
        username: 'court-journal',
        ed25519PubBase64: 'JJJJ',
        x25519PubBase64: 'KKKK',
        isBot: true,
        ownerUsername: 'court',
      ),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: CreateChatPickScreen(selfUsername: 'court'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('familiar-row-court-garden')), findsOneWidget);
    expect(find.byKey(const Key('familiar-row-court-journal')), findsOneWidget);
  });

  testWidgets('shows partner-empty hint when no partner is paired', (
    tester,
  ) async {
    final conn = _FakeConn();
    final container = await _container(conn: conn);
    // No rooms → no partner yet.

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: CreateChatPickScreen(selfUsername: 'court'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('partner-row')), findsNothing);
    expect(find.byKey(const Key('partner-empty-hint')), findsOneWidget);
    expect(find.byKey(const Key('familiars-empty-hint')), findsOneWidget);
    // Both empty → Create chat is disabled.
    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('create-chat-button')),
    );
    expect(btn.onPressed, isNull);
  });
}
