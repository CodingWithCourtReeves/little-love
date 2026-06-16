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

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  RetryCallback? onRetry,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_) {},
          onRetry: onRetry,
        ),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [accountProvider.overrideWith((_) async => _account)],
  );
  return container;
}

void main() {
  testWidgets('a sent message carries a heart inside its own bubble', (
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
            body: 'hi',
            ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
          ),
        );

    await _pump(tester, container);
    expect(find.byKey(const Key('status-heart')), findsOneWidget);
    expect(find.byKey(const Key('status-clock')), findsNothing);
    expect(find.text('failed · tap to retry'), findsNothing);
  });

  testWidgets(
    'every message in a sent run gets its own heart — no collapsing',
    (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await container.read(accountProvider.future);

      final store = container.read(messageStoreProvider('r1').notifier);
      for (var i = 0; i < 3; i++) {
        store.add(
          Msg(
            id: 'srv-$i',
            from: 'me',
            to: 'r1',
            body: 'msg $i',
            ts: DateTime.utc(2026, 6, 13, 10, i),
          ),
        );
      }

      await _pump(tester, container);
      // Telegram style: three sent messages → three hearts, one per bubble.
      expect(find.byKey(const Key('status-heart')), findsNWidgets(3));
    },
  );

  testWidgets('a message in flight shows a clock, not a "sending…" caption', (
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
            body: 'on my way',
            ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
            clientMsgId: 'cli-1',
            sendStatus: SendStatus.sending,
          ),
        );

    await _pump(tester, container);
    expect(find.byKey(const Key('status-clock')), findsOneWidget);
    expect(find.byKey(const Key('status-heart')), findsNothing);
    expect(find.text('sending…'), findsNothing);
  });

  testWidgets('every in-flight message in a run gets its own clock', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    final store = container.read(messageStoreProvider('r1').notifier);
    for (var i = 0; i < 2; i++) {
      store.add(
        Msg(
          id: 'cli-$i',
          from: 'me',
          to: 'r1',
          body: 'msg $i',
          ts: DateTime.utc(2026, 6, 13, 10, i),
          clientMsgId: 'cli-$i',
          sendStatus: SendStatus.sending,
        ),
      );
    }

    await _pump(tester, container);
    expect(find.byKey(const Key('status-clock')), findsNWidgets(2));
    expect(find.byKey(const Key('status-heart')), findsNothing);
  });

  testWidgets('a single failed message shows the caption and tap retries', (
    tester,
  ) async {
    final retried = <String>[];
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
            body: 'eh',
            ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
            clientMsgId: 'cli-1',
            sendStatus: SendStatus.failed,
          ),
        );

    await _pump(tester, container, onRetry: retried.add);
    expect(find.text('failed · tap to retry'), findsOneWidget);
    // A failed message gets no in-bubble heart or clock.
    expect(find.byKey(const Key('status-heart')), findsNothing);
    expect(find.byKey(const Key('status-clock')), findsNothing);
    await tester.tap(find.text('eh'));
    expect(retried, ['cli-1']);
  });

  testWidgets(
    'a failed run shows one caption below and tap retries the stack',
    (tester) async {
      final retried = <String>[];
      final container = _container();
      addTearDown(container.dispose);
      await container.read(accountProvider.future);

      final store = container.read(messageStoreProvider('r1').notifier);
      for (var i = 0; i < 2; i++) {
        store.add(
          Msg(
            id: 'cli-$i',
            from: 'me',
            to: 'r1',
            body: 'fail $i',
            ts: DateTime.utc(2026, 6, 13, 10, i),
            clientMsgId: 'cli-$i',
            sendStatus: SendStatus.failed,
          ),
        );
      }

      await _pump(tester, container, onRetry: retried.add);
      // Failed stays collapsed: one caption for the whole run.
      expect(find.text('failed · tap to retry'), findsOneWidget);
      await tester.tap(find.text('fail 1'));
      expect(retried, ['cli-0', 'cli-1']);
    },
  );

  testWidgets('a failure in a run is never hidden by a still-sending sibling', (
    tester,
  ) async {
    final retried = <String>[];
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    // An earlier message failed; a later one is still sending. The failure
    // surfaces as the caption while the in-flight message keeps its clock.
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(
      Msg(
        id: 'cli-0',
        from: 'me',
        to: 'r1',
        body: 'first',
        ts: DateTime.utc(2026, 6, 13, 10, 0),
        clientMsgId: 'cli-0',
        sendStatus: SendStatus.failed,
      ),
    );
    store.add(
      Msg(
        id: 'cli-1',
        from: 'me',
        to: 'r1',
        body: 'second',
        ts: DateTime.utc(2026, 6, 13, 10, 1),
        clientMsgId: 'cli-1',
        sendStatus: SendStatus.sending,
      ),
    );

    await _pump(tester, container, onRetry: retried.add);
    expect(find.text('failed · tap to retry'), findsOneWidget);
    expect(find.byKey(const Key('status-clock')), findsOneWidget);
    // The caption anchors to the failed message itself; tapping it re-sends
    // only the failed member. The still-sending sibling is not a retry target.
    await tester.tap(find.text('second'));
    expect(retried, isEmpty);
    await tester.tap(find.text('first'));
    expect(retried, ['cli-0']);
  });

  testWidgets('the failed caption anchors to the failed message, not a later '
      'sent sibling', (tester) async {
    final retried = <String>[];
    final container = _container();
    addTearDown(container.dispose);
    await container.read(accountProvider.future);

    // A message failed; a later one in the same run succeeded. The caption and
    // its tap target belong to the failed bubble, not the one that went through.
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(
      Msg(
        id: 'cli-0',
        from: 'me',
        to: 'r1',
        body: 'oops',
        ts: DateTime.utc(2026, 6, 13, 10, 0),
        clientMsgId: 'cli-0',
        sendStatus: SendStatus.failed,
      ),
    );
    store.add(
      Msg(
        id: 'srv-1',
        from: 'me',
        to: 'r1',
        body: 'made it',
        ts: DateTime.utc(2026, 6, 13, 10, 1),
      ),
    );

    await _pump(tester, container, onRetry: retried.add);
    expect(find.text('failed · tap to retry'), findsOneWidget);
    // The succeeded sibling keeps its heart and is not a retry target.
    expect(find.byKey(const Key('status-heart')), findsOneWidget);
    await tester.tap(find.text('made it'));
    expect(retried, isEmpty);
    await tester.tap(find.text('oops'));
    expect(retried, ['cli-0']);
  });
}
