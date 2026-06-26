import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/reply_ref.dart';
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
  homeDirectory: Directory.systemTemp.createTempSync('conv_reply_rs'),
);

ProviderContainer _container(List<Msg> messages) {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith((_) async => _account),
      httpClientProvider.overrideWithValue(http.Client()),
      readStateStoreProvider.overrideWithValue(_readStateStore),
    ],
  );
  container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
  container.read(messageStoreProvider('roomA').notifier).setAll(messages);
  return container;
}

Widget _app(ProviderContainer container, {SendCallback? onSend}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: ConversationPage(
          room: _roomA(),
          selfUsername: 'court',
          onSend: onSend ?? (_, _) {},
          onReact: (_, _) {},
        ),
      ),
    );

void main() {
  testWidgets('renders a reply quote from the cached snippet when the target '
      'is not loaded', (tester) async {
    final container = _container([
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'me too',
        ts: DateTime.utc(2026, 6, 9, 17, 4),
        replyTo: const ReplyRef(
          id: 'gone',
          author: 'kaitlyn',
          kind: 'text',
          text: 'miss you',
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reply-quote-2')), findsOneWidget);
    // The stacked-faded quote shows the cached snippet (iMessage-style; the
    // author label lives on the composer banner, not the quote).
    expect(
      find.descendant(
        of: find.byKey(const Key('reply-quote-2')),
        matching: find.text('miss you'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('reply quote prefers the live target over the cached snippet', (
    tester,
  ) async {
    final container = _container([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'the live text',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'reply',
        ts: DateTime.utc(2026, 6, 9, 17, 4),
        replyTo: const ReplyRef(
          id: '1',
          author: 'kaitlyn',
          kind: 'text',
          text: 'STALE cached text',
        ),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    // The quote shows the live body, not the stale cached snippet.
    expect(find.text('STALE cached text'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('reply-quote-2')),
        matching: find.text('the live text'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('long-press Reply raises the composer reply banner', (
    tester,
  ) async {
    final container = _container([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'hello love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hello love'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-reply')), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-reply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reply-banner')), findsOneWidget);
    expect(find.text('Replying to kaitlyn'), findsOneWidget);
  });

  testWidgets(
    'sending while replying attaches replyTo then clears the banner',
    (tester) async {
      ReplyRef? sentReply;
      var sentCount = 0;
      final container = _container([
        Msg(
          id: '1',
          from: 'kaitlyn',
          to: 'court',
          body: 'hello love',
          ts: DateTime.utc(2026, 6, 9, 17, 2),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _app(
          container,
          onSend: (_, replyTo) {
            sentReply = replyTo;
            sentCount++;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('hello love'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action-reply')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('composer')), 'replying now');
      await tester.pump();
      await tester.tap(find.byKey(const Key('composer-send')));
      await tester.pumpAndSettle();

      expect(sentCount, 1);
      expect(sentReply, isNotNull);
      expect(sentReply!.id, '1');
      expect(sentReply!.author, 'kaitlyn');
      expect(sentReply!.kind, 'text');
      // Banner clears after the send.
      expect(find.byKey(const Key('reply-banner')), findsNothing);
    },
  );

  testWidgets('an "N replies" pill opens the focused thread view', (
    tester,
  ) async {
    final container = _container([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'dinner tonight?',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'yes please',
        ts: DateTime.utc(2026, 6, 9, 17, 4),
        replyTo: const ReplyRef(id: '1', author: 'kaitlyn', kind: 'text'),
      ),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('1 reply'), findsOneWidget);
    await tester.tap(find.text('1 reply'));
    await tester.pumpAndSettle();

    // Focused thread view is up with its own composer and both messages.
    expect(find.byKey(const Key('thread-composer')), findsOneWidget);
    expect(find.text('dinner tonight?'), findsWidgets);
    expect(find.text('yes please'), findsWidgets);
  });

  testWidgets(
    'tapping a reply quote does not throw when the target is present',
    (tester) async {
      final container = _container([
        Msg(
          id: '1',
          from: 'kaitlyn',
          to: 'court',
          body: 'jump target',
          ts: DateTime.utc(2026, 6, 9, 17, 2),
        ),
        Msg(
          id: '2',
          from: 'court',
          to: 'kaitlyn',
          body: 'reply',
          ts: DateTime.utc(2026, 6, 9, 17, 4),
          replyTo: const ReplyRef(id: '1', author: 'kaitlyn', kind: 'text'),
        ),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reply-quote-2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    },
  );
}
