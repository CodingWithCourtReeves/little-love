import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Room _room() => Room(
      roomId: 'r1',
      name: 'Kaitlyn',
      members: const [
        Member(
          username: 'me',
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
      createdAt: DateTime.utc(2026, 6, 13),
    );

final _account = LocalAccount(
  username: 'me',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 13),
);

void main() {
  testWidgets('mine bubble shows "sending…" caption when status=sending',
      (tester) async {
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => _account),
    ]);
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container.read(messageStoreProvider('r1').notifier).add(Msg(
          id: 'cli-1',
          from: 'me',
          to: 'r1',
          body: 'on my way',
          ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
          clientMsgId: 'cli-1',
          sendStatus: SendStatus.sending,
        ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('sending…'), findsOneWidget);
    expect(find.text('failed · tap to retry'), findsNothing);
  });

  testWidgets('failed bubble shows retry caption and tap invokes onRetry',
      (tester) async {
    final retried = <String>[];
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => _account),
    ]);
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container.read(messageStoreProvider('r1').notifier).add(Msg(
          id: 'cli-1',
          from: 'me',
          to: 'r1',
          body: 'eh',
          ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
          clientMsgId: 'cli-1',
          sendStatus: SendStatus.failed,
        ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_) {},
          onRetry: (clientMsgId) => retried.add(clientMsgId),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('failed · tap to retry'), findsOneWidget);
    await tester.tap(find.text('eh'));
    expect(retried, ['cli-1']);
  });

  testWidgets('sent bubble has no caption', (tester) async {
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => _account),
    ]);
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container.read(messageStoreProvider('r1').notifier).add(Msg(
          id: 'srv-1',
          from: 'me',
          to: 'r1',
          body: 'hi',
          ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
        ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('sending…'), findsNothing);
    expect(find.text('failed · tap to retry'), findsNothing);
  });
}
