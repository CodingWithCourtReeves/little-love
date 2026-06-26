import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
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
  homeDirectory: Directory.systemTemp.createTempSync('conv_anim_rs'),
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith((_) async => _account),
      httpClientProvider.overrideWithValue(http.Client()),
      readStateStoreProvider.overrideWithValue(_readStateStore),
    ],
  );
  container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: ConversationPage(
          room: _roomA(),
          selfUsername: 'court',
          onSend: (_, __) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The opacity of the pop-in wrapper around the bubble with [id], or null if
/// the bubble is not wrapped (i.e. it was seeded history / already animated).
double? _popOpacity(WidgetTester tester, String id) {
  final wrapper = find.byKey(Key('popin-$id'));
  if (wrapper.evaluate().isEmpty) return null;
  final opacity = find.descendant(of: wrapper, matching: find.byType(Opacity));
  return tester.widget<Opacity>(opacity.first).opacity;
}

void main() {
  testWidgets('a newly added message animates in; existing ones do not', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'old',
        ts: DateTime.utc(2026, 6, 9, 17, 1),
      ),
    ]);
    await _pump(tester, container);

    // Seeded history is not wrapped — no pop on room open.
    expect(find.byKey(const Key('popin-1')), findsNothing);

    // Add a new message; pump one frame to build the wrapper, then a short
    // slice so the animation is mid-flight.
    store.add(
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'new',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byKey(const Key('popin-2')), findsOneWidget);
    final midOpacity = _popOpacity(tester, '2');
    expect(midOpacity, isNotNull);
    expect(midOpacity, lessThan(1.0)); // still fading in

    await tester.pumpAndSettle();
    expect(_popOpacity(tester, '2'), 1.0); // settles fully opaque
  });

  testWidgets('history that hydrates after the first build does not pop', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    // Store is empty when the page first builds (the local DB hydrates async,
    // landing after open) — the seed must not fire on this empty build.
    store.setAll(const []);
    await _pump(tester, container);

    // Hydration lands: a batch of existing history.
    store.setAll([
      Msg(
        id: 'h1',
        from: 'kaitlyn',
        to: 'court',
        body: 'one',
        ts: DateTime.utc(2026, 6, 9, 16, 0),
      ),
      Msg(
        id: 'h2',
        from: 'court',
        to: 'kaitlyn',
        body: 'two',
        ts: DateTime.utc(2026, 6, 9, 16, 1),
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // Neither hydrated row pops in — they were seeded as existing history.
    expect(find.byKey(const Key('popin-h1')), findsNothing);
    expect(find.byKey(const Key('popin-h2')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('an optimistic send does not re-pop after reconcile', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    // Seed one prior message so the store is non-empty on first build (history
    // is seeded), making the optimistic send below a genuine new arrival.
    store.setAll([
      Msg(
        id: 'h0',
        from: 'kaitlyn',
        to: 'court',
        body: 'earlier',
        ts: DateTime.utc(2026, 6, 9, 16),
      ),
    ]);
    await _pump(tester, container);

    // Optimistic send: the local echo's id IS the client msg id (that is how
    // the real send path adds it, and how reconcile finds it to swap).
    store.add(
      Msg(
        id: 'cmid-1',
        clientMsgId: 'cmid-1',
        from: 'court',
        to: 'kaitlyn',
        body: 'sent',
        ts: DateTime.utc(2026, 6, 9, 17, 5),
      ),
    );
    await tester.pumpAndSettle(); // first pop completes

    // Reconcile to the authoritative server id (same clientMsgId).
    store.reconcile(
      'cmid-1',
      Msg(
        id: 'server-1',
        clientMsgId: 'cmid-1',
        from: 'court',
        to: 'kaitlyn',
        body: 'sent',
        ts: DateTime.utc(2026, 6, 9, 17, 5),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    // The reconciled row keys off cmid-1, which already animated, so it is not
    // wrapped again — under neither the optimistic nor the server id.
    expect(find.byKey(const Key('popin-cmid-1')), findsNothing);
    expect(find.byKey(const Key('popin-server-1')), findsNothing);
    expect(find.text('sent'), findsOneWidget);
  });
}
