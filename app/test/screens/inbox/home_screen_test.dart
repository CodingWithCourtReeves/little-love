import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/inbox/home_screen.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';

/// A pairing transport whose calls never resolve — enough for the empty-state
/// (PairingScreen) to mount and show its spinner without a real socket.
class _PendingTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() =>
      Completer<InviteCreatedFrame>().future;
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => Completer<InviteConsumedFrame>().future;
}

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

/// A room you're the only member of — the interim state right after creating an
/// invite, before the partner consumes it.
Room _soloRoom(String id) => Room(
  roomId: id,
  name: '',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
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
      // PairingScreen (the empty state) reads this in initState; the live
      // connection is held pending so the real provider would throw.
      pairingTransportProvider.overrideWithValue(_PendingTransport()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  testWidgets('empty inbox, once synced, shows the pairing affordance', (
    tester,
  ) async {
    final c = _container();
    c.read(inboxSyncedProvider.notifier).state = true;
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    expect(find.text('PAIR WITH YOUR PARTNER'), findsOneWidget);
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets('empty inbox before first sync shows no pairing flash', (
    tester,
  ) async {
    final c = _container(); // not synced; live connection held pending
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    // Blank canvas while the room list is still in flight — no pairing screen.
    expect(find.text('PAIR WITH YOUR PARTNER'), findsNothing);
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets('a room with an unread partner message shows an unread dot', (
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
    // An incoming message in room2, none in room1.
    c
        .read(messageStoreProvider('room2').notifier)
        .add(
          Msg(
            id: '1',
            from: 'kaitlyn',
            to: 'room2',
            body: 'miss you',
            ts: DateTime.utc(2026, 6, 12),
          ),
        );
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byKey(const Key('home-room-room2')),
        matching: find.byKey(const Key('unread-dot')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('home-room-room1')),
        matching: find.byKey(const Key('unread-dot')),
      ),
      findsNothing,
    );
  });

  testWidgets('my own message does not mark a room unread', (tester) async {
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
    c
        .read(messageStoreProvider('room2').notifier)
        .add(
          Msg(
            id: '1',
            from: 'court',
            to: 'room2',
            body: 'hey',
            ts: DateTime.utc(2026, 6, 12),
          ),
        );
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pump();
    expect(find.byKey(const Key('unread-dot')), findsNothing);
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

  testWidgets('a lone solo invite room does NOT auto-open (no dump)', (
    tester,
  ) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([_soloRoom('room1')]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pumpAndSettle();
    // Creating an invite must not throw you into an empty conversation.
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets(
    'when paired, [+] opens the new-channel sheet (no invite options)',
    (tester) async {
      final c = _container();
      // Two rooms (so no auto-open), at least one a real partner room => paired.
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

      await tester.tap(find.byKey(const Key('home-new-chat')));
      await tester.pumpAndSettle();
      // The create-channel sheet, not the pairing options.
      expect(find.text('New channel'), findsOneWidget);
      expect(find.text('Invite them with a code'), findsNothing);
    },
  );

  testWidgets('when not yet paired, [+] still offers the pairing options', (
    tester,
  ) async {
    final c = _container();
    c.read(inboxStateProvider.notifier).setRooms([_soloRoom('room1')]);
    await tester.pumpWidget(_app(c, _acct()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-new-chat')));
    await tester.pumpAndSettle();
    expect(find.text('Invite them with a code'), findsOneWidget);
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
