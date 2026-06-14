import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/inbox/sidebar.dart';
import 'package:littlelove/theme/twilight.dart';
import 'package:littlelove/wire/frames.dart';

Room _r(String id, String peer) => Room(
  roomId: id,
  name: '',
  members: [
    const Member(
      username: 'court',
      ed25519PubBase64: '',
      x25519PubBase64: '',
      isBot: false,
    ),
    Member(
      username: peer,
      ed25519PubBase64: 'AAA',
      x25519PubBase64: 'BBB',
      isBot: false,
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 9),
);

Widget _harness({required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTwilightTheme(),
      home: const Scaffold(
        body: SizedBox(width: 240, child: Sidebar(username: 'court')),
      ),
    ),
  );
}

void main() {
  testWidgets('renders Couples header and each room', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([
      _r('1', 'kaitlyn'),
      _r('2', 'sage'),
    ]);
    await tester.pumpWidget(_harness(container: container));
    expect(find.text('PARTNER'), findsOneWidget);
    expect(find.text('FAMILIARS'), findsOneWidget);
    expect(find.text('Kaitlyn'), findsOneWidget);
    expect(find.text('Sage'), findsOneWidget);
    expect(find.text('@court'), findsOneWidget);
  });

  testWidgets('tapping a room updates selectedRoomId', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    await tester.pumpWidget(_harness(container: container));
    await tester.tap(find.text('Kaitlyn'));
    await tester.pump();
    expect(container.read(inboxStateProvider).selectedRoomId, '1');
  });
}
