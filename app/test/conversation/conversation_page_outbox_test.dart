import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  testWidgets('mine bubble shows "sending…" caption when status=sending',
      (tester) async {
    final acc = LocalAccount(
      username: 'me',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => acc),
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
          roomId: 'r1',
          contactDisplayName: 'Kaitlyn',
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
    final acc = LocalAccount(
      username: 'me',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => acc),
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
          roomId: 'r1',
          contactDisplayName: 'Kaitlyn',
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
    final acc = LocalAccount(
      username: 'me',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => acc),
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
          roomId: 'r1',
          contactDisplayName: 'Kaitlyn',
          onSend: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('sending…'), findsNothing);
    expect(find.text('failed · tap to retry'), findsNothing);
  });
}
