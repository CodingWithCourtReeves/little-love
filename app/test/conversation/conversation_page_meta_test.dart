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
    Member(username: 'me', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
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

ProviderContainer _container() => ProviderContainer(
  overrides: [accountProvider.overrideWith((_) async => _account)],
);

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('my message shows its hh:mm timestamp beside the heart', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    // Local time so the rendered hh:mm is machine-timezone independent.
    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-1',
            from: 'me',
            to: 'r1',
            body: 'hi',
            ts: DateTime(2026, 6, 13, 10, 5),
          ),
        );

    await _pump(tester, container);
    expect(find.text('10:05'), findsOneWidget);
    expect(find.byKey(const Key('status-heart')), findsOneWidget);
  });

  testWidgets('a read message shows the double heart, not the single', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-1',
            from: 'me',
            to: 'r1',
            body: 'miss you',
            ts: DateTime(2026, 6, 13, 10, 5),
            sendStatus: SendStatus.read,
          ),
        );

    await _pump(tester, container);
    expect(find.byKey(const Key('status-double-heart')), findsOneWidget);
    expect(find.byKey(const Key('status-heart')), findsNothing);
    expect(find.byKey(const Key('status-clock')), findsNothing);
  });

  testWidgets('a message sent to me shows its hh:mm timestamp, no marker', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-2',
            from: 'kaitlyn',
            to: 'r1',
            body: 'hey',
            ts: DateTime(2026, 6, 13, 10, 7),
          ),
        );

    await _pump(tester, container);
    expect(find.text('10:07'), findsOneWidget);
    expect(find.byKey(const Key('status-heart')), findsNothing);
    expect(find.byKey(const Key('status-clock')), findsNothing);
  });

  testWidgets('an in-flight message shows its timestamp beside the clock', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'cli-1',
            from: 'me',
            to: 'r1',
            body: 'omw',
            ts: DateTime(2026, 6, 13, 10, 9),
            clientMsgId: 'cli-1',
            sendStatus: SendStatus.sending,
          ),
        );

    await _pump(tester, container);
    expect(find.text('10:09'), findsOneWidget);
    expect(find.byKey(const Key('status-clock')), findsOneWidget);
  });

  testWidgets('timestamps are 24-hour and zero-padded', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(
      Msg(
        id: 'srv-3',
        from: 'me',
        to: 'r1',
        body: 'morning',
        ts: DateTime(2026, 6, 13, 9, 3),
      ),
    );
    store.add(
      Msg(
        id: 'srv-4',
        from: 'me',
        to: 'r1',
        body: 'afternoon',
        ts: DateTime(2026, 6, 13, 14, 32),
      ),
    );

    await _pump(tester, container);
    expect(find.text('09:03'), findsOneWidget);
    expect(find.text('14:32'), findsOneWidget);
  });

  testWidgets('message bubbles have no hover tooltip', (tester) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-5',
            from: 'me',
            to: 'r1',
            body: 'no-tooltip-please',
            ts: DateTime(2026, 6, 13, 10, 0),
          ),
        );

    await _pump(tester, container);
    expect(
      find.ancestor(
        of: find.text('no-tooltip-please'),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
    );
  });

  testWidgets('the meta flows after the text, not in a reserved column', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    const longBody =
        'this is a much longer message that should wrap across several lines '
        'inside the bubble for sure okay';
    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-6',
            from: 'me',
            to: 'r1',
            body: longBody,
            ts: DateTime(2026, 6, 13, 10, 6),
          ),
        );

    await _pump(tester, container);
    // A reserved gutter overlaps the meta onto the last text line and carves an
    // empty column down the right. The meta should instead follow the text
    // block — its top at or below the text's bottom.
    final textBottom = tester.getRect(find.text(longBody)).bottom;
    final timeTop = tester.getRect(find.text('10:06')).top;
    expect(timeTop, greaterThanOrEqualTo(textBottom - 1));
  });
}
