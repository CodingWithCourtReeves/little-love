// HomeScreen navigation when a channel goes away, driven through the real
// RoomMessageRouter: frames arrive on a fake socket and the router hides,
// purges and announces the room exactly as it does in the app. Mounting the
// screen with rooms set by hand misses the bugs here, which live in the order
// the router changes the inbox and the order HomeScreen reacts.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/chat_info_page.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/room_message_router.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/push/push_bootstrap.dart';
import 'package:littlelove/screens/inbox/home_screen.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../outbox/memory_outbox_store.dart';
import '../../support/test_read_state.dart';

class _FakeConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Object> sent = [];

  /// Answer my delete as a server that no longer has the room would.
  bool roomAlreadyGone = false;

  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) {
    sent.add(payload);
    // The server's answer to my delete: RoomDeleted to both of us.
    if (payload case {'kind': 'DeleteRoom', 'room_id': final String id}) {
      scheduleMicrotask(
        () => emit(
          roomAlreadyGone
              ? RoomErrorFrame(code: 'UnknownRoom', message: '', roomId: id)
              : RoomDeletedFrame(roomId: id, deletedBy: 'court'),
        ),
      );
    }
  }

  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async => _ctl.close();

  void emit(RoomServerFrame f) => _ctl.add(f);
}

Member _member(String username, DerivedIdentity id) => Member(
  username: username,
  ed25519PubBase64: base64.encode(id.ed25519PublicKey),
  x25519PubBase64: base64.encode(id.x25519PublicKey),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete. In-process queries resolve on microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  late DerivedIdentity me;
  late DerivedIdentity peer;

  RoomsFrame roomsFrame(List<(String, String)> rooms) => RoomsFrame(
    rooms: [
      for (final (id, name) in rooms)
        RoomDetail(
          roomId: id,
          name: name,
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
    ],
  );

  /// Polls [ready], pumping frames between checks, so router work (db reads,
  /// purges) finishes under the widget clock.
  Future<void> pumpUntil(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ready(), isTrue, reason: 'condition never became true');
  }

  /// HomeScreen on a live session whose server lists [rooms].
  Future<(ProviderContainer, _FakeConn)> connect(
    WidgetTester tester,
    List<(String, String)> rooms,
  ) async {
    final conn = _FakeConn();
    final account = LocalAccount(
      username: 'court',
      ed25519PubBase64: base64.encode(me.ed25519PublicKey),
      x25519PubBase64: base64.encode(me.x25519PublicKey),
      createdAt: DateTime.utc(2026, 6, 10),
    );
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    final OutboxStore outbox = MemoryOutboxStore();
    final c = ProviderContainer(
      overrides: [
        liveConnectionProvider.overrideWith((_) async => conn),
        currentIdentityProvider.overrideWith((_) async => me),
        accountProvider.overrideWith((_) async => account),
        messageDbProvider.overrideWith((_) async => MessageDb.test(db)),
        outboxStoreProvider.overrideWith((_) async => outbox),
        hermeticReadStateStore(),
        // No APNs in a widget test.
        pushBootstrapProvider.overrideWith((_) {}),
      ],
    );
    addTearDown(c.dispose);
    // Tear-downs run last-first: unmount the screen before the container
    // goes, so no page's dispose reaches a disposed provider.
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: HomeScreen(account: account),
        ),
      ),
    );
    await pumpUntil(tester, () => c.exists(roomMessageRouterProvider));
    conn.emit(roomsFrame(rooms));
    await pumpUntil(tester, () => c.read(inboxSyncedProvider));
    await tester.pumpAndSettle();
    return (c, conn);
  }

  Future<void> openRow(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);
  }

  /// From inside a channel: chat info, Delete channel, type [typed], confirm.
  Future<void> deleteFromChatInfo(WidgetTester tester, String typed) async {
    await tester.tap(find.byKey(const Key('room-title-pill')));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('chat-info-delete-channel'));
    // Below the fold of the info page's lazy list: scroll until it's built.
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ChatInfoPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      typed,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-channel-confirm')));
  }

  /// Let a toast that is showing run out, so no timer outlives the test.
  Future<void> drainToast(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 4));

  setUp(() async {
    me = await deriveIdentity(seedA);
    peer = await deriveIdentity(seedB);
  });

  testWidgets('on the inbox, my partner deleting the only other channel '
      'leaves me on the inbox (no jump into the partner chat)', (tester) async {
    final (c, conn) = await connect(tester, [('dm', ''), ('chan', 'Travel')]);
    expect(find.byType(ConversationPage), findsNothing);

    conn.emit(const RoomDeletedFrame(roomId: 'chan', deletedBy: 'kaitlyn'));
    await pumpUntil(tester, () => c.read(inboxStateProvider).rooms.length == 1);
    await tester.pumpAndSettle();

    expect(find.text('Travel'), findsNothing);
    expect(find.byType(ConversationPage), findsNothing);
    expect(find.textContaining('deleted'), findsNothing);
  });

  testWidgets('deleting the last channel from inside it lands on the inbox, '
      'and a later rebuild does not open the partner chat', (tester) async {
    final (c, conn) = await connect(tester, [('dm', ''), ('chan', 'Travel')]);
    await openRow(tester, 'Travel');

    await deleteFromChatInfo(tester, 'travel');
    await pumpUntil(
      tester,
      () => find.text('Channel deleted').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // Back on the inbox: the sheet, info page and chat are all gone, and
    // the inbox itself is still there.
    expect(find.byType(ConversationPage), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Travel'), findsNothing);
    expect(c.read(inboxStateProvider).rooms.map((r) => r.roomId), ['dm']);

    // A reconnect republishes the list: HomeScreen rebuilds with one room.
    conn.emit(roomsFrame([('dm', '')]));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
    await drainToast(tester);
  });

  testWidgets('deleting a channel the server already lost (deleted while '
      'this phone was away) still closes it and removes it here', (
    tester,
  ) async {
    final (c, conn) = await connect(tester, [('dm', ''), ('chan', 'Travel')]);
    conn.roomAlreadyGone = true;
    await openRow(tester, 'Travel');

    await deleteFromChatInfo(tester, 'travel');
    await pumpUntil(
      tester,
      () => find.text('Channel deleted').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConversationPage), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(c.read(inboxStateProvider).rooms.map((r) => r.roomId), ['dm']);
    await drainToast(tester);
  });

  testWidgets('a chat whose channel is missing from a reconnect\'s room list '
      'closes with a toast instead of staying open and empty', (tester) async {
    final (c, conn) = await connect(tester, [
      ('dm', ''),
      ('chan', 'Travel'),
      ('chan2', 'Food'),
    ]);
    await openRow(tester, 'Travel');

    conn.emit(roomsFrame([('dm', ''), ('chan2', 'Food')]));
    await pumpUntil(
      tester,
      () => find.text('Travel was deleted').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConversationPage), findsNothing);
    expect(c.read(inboxStateProvider).rooms.map((r) => r.roomId), [
      'dm',
      'chan2',
    ]);
    await drainToast(tester);
  });

  testWidgets('my partner deleting an open channel with a blank name (an old '
      'build allowed one) says the chat was deleted, not "deleted "', (
    tester,
  ) async {
    final (c, conn) = await connect(tester, [('dm', ''), ('chan', '  ')]);
    c.read(requestedRoomProvider.notifier).state = 'chan';
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chan')), findsOneWidget);

    conn.emit(const RoomDeletedFrame(roomId: 'chan', deletedBy: 'kaitlyn'));
    await pumpUntil(
      tester,
      () => find.text('This chat was deleted').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConversationPage), findsNothing);
    await drainToast(tester);
  });

  testWidgets('a channel deleted under another open chat is taken out of the '
      'back stack, with nothing shown', (tester) async {
    final (c, conn) = await connect(tester, [('dm', ''), ('chan', 'Travel')]);
    await openRow(tester, 'Travel');
    // A notification tap opens the partner chat on top of Travel.
    c.read(requestedRoomProvider.notifier).state = 'dm';
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(find.byKey(const ValueKey('dm')), findsOneWidget);

    conn.emit(const RoomDeletedFrame(roomId: 'chan', deletedBy: 'kaitlyn'));
    await pumpUntil(tester, () => c.read(inboxStateProvider).rooms.length == 1);
    await tester.pumpAndSettle();

    // Still in the partner chat, told nothing.
    expect(find.byKey(const ValueKey('dm')), findsOneWidget);
    expect(find.textContaining('deleted'), findsNothing);

    // Back goes to the inbox, not into an empty Travel.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
    expect(find.text('Kaitlyn'), findsWidgets);
  });
}
