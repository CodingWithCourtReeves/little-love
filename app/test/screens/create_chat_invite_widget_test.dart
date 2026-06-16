import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/pending_invites_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/screens/create_chat/create_chat_invite_screen.dart';
import 'package:littlelove/wire/frames.dart';

Room _soloRoom() => Room(
  roomId: 'rNEW',
  name: '',
  members: const [
    Member(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
    ),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'GGGG',
      x25519PubBase64: 'HHHH',
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  testWidgets('renders 4-word code + roster + Copy code copies to clipboard', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_soloRoom()]);
    container
        .read(pendingInvitesProvider.notifier)
        .set(
          'rNEW',
          PendingInvite(
            code: 'amber-fern-locket-tide',
            qrPngBase64: '',
            expiresAt: DateTime.utc(2026, 6, 10, 19),
          ),
        );

    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final text = (call.arguments as Map)['text'] as String;
            copied.add(text);
          }
          return null;
        });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CreateChatInviteScreen(roomId: 'rNEW')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('amber-fern-locket-tide'), findsOneWidget);
    // Roster: court IN, kaitlyn IN, Partner PENDING
    expect(find.text('court'), findsOneWidget);
    expect(find.text('kaitlyn'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('copy-code-button')));
    await tester.tap(find.byKey(const Key('copy-code-button')));
    await tester.pumpAndSettle();
    expect(copied, ['amber-fern-locket-tide']);
  });

  testWidgets('Done invokes onDone instead of popping the navigator', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_soloRoom()]);
    container
        .read(pendingInvitesProvider.notifier)
        .set(
          'rNEW',
          PendingInvite(
            code: 'amber-fern-locket-tide',
            qrPngBase64: '',
            expiresAt: DateTime.utc(2026, 6, 10, 19),
          ),
        );

    var doneCalls = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: CreateChatInviteScreen(
            roomId: 'rNEW',
            onDone: () => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('done-button')));
    await tester.tap(find.byKey(const Key('done-button')));
    await tester.pumpAndSettle();

    expect(doneCalls, 1);
  });

  testWidgets('shows waiting placeholder when no pending invite is known', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: CreateChatInviteScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Waiting'), findsOneWidget);
  });
}
