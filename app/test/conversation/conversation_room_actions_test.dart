import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 10),
);

Room _coupleRoom() => Room(
  roomId: 'rRoom',
  name: 'Original',
  members: const [
    Member(
      username: 'court',
      ed25519PubBase64: 'AAA',
      x25519PubBase64: 'BBB',
      isBot: false,
    ),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
      isBot: false,
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

Room _threeMemberRoom() => Room(
  roomId: 'rTri',
  name: '',
  members: const [
    Member(
      username: 'court',
      ed25519PubBase64: 'AAA',
      x25519PubBase64: 'BBB',
      isBot: false,
    ),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
      isBot: false,
    ),
    Member(
      username: 'court-garden',
      ed25519PubBase64: 'EEE',
      x25519PubBase64: 'FFF',
      isBot: true,
      ownerUsername: 'court',
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      accountProvider.overrideWith((_) async => _account),
      httpClientProvider.overrideWithValue(http.Client()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('rename menu opens dialog and calls onRename with new name', (
    tester,
  ) async {
    final container = _container();
    String? renamed;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ConversationPage(
            room: _coupleRoom(),
            selfUsername: 'court',
            onSend: (_) {},
            onRename: (n) => renamed = n,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('room-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-menu-rename')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('rename-dialog-field')),
      'Daily life',
    );
    await tester.tap(find.byKey(const Key('rename-dialog-save')));
    await tester.pumpAndSettle();

    expect(renamed, 'Daily life');
  });

  testWidgets(
    'sender labels render in 3+ member rooms and are absent in 2-member rooms',
    (tester) async {
      final container = _container();
      container.read(messageStoreProvider('rTri').notifier).setAll([
        Msg(
          id: 'm1',
          from: 'kaitlyn',
          to: 'court',
          body: 'hi from kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
        ),
      ]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ConversationPage(
              room: _threeMemberRoom(),
              selfUsername: 'court',
              onSend: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sender-label-m1')), findsOneWidget);
    },
  );

  testWidgets('sender labels are NOT rendered in 2-member rooms', (
    tester,
  ) async {
    final container = _container();
    container.read(messageStoreProvider('rRoom').notifier).setAll([
      Msg(
        id: 'm1',
        from: 'kaitlyn',
        to: 'court',
        body: 'hi',
        ts: DateTime.utc(2026, 6, 10, 12),
      ),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ConversationPage(
            room: _coupleRoom(),
            selfUsername: 'court',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sender-label-m1')), findsNothing);
  });
}
