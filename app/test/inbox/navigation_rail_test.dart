import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/navigation_rail.dart';
import 'package:littlelove/inbox/room.dart';
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
      home: const Scaffold(body: NavigationRailChrome()),
    ),
  );
}

void main() {
  testWidgets('tapping a rail entry updates selectedRoomId', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([
      _r('1', 'kaitlyn'),
      _r('2', 'sage'),
    ]);
    container.read(inboxStateProvider.notifier).select('1');
    await tester.pumpWidget(_harness(container: container));
    await tester.tap(find.byKey(const Key('rail-room-2')));
    await tester.pump();
    expect(container.read(inboxStateProvider).selectedRoomId, '2');
  });

  testWidgets('rail icon entries are at least 44x44', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'k')]);
    await tester.pumpWidget(_harness(container: container));
    final size = tester.getSize(find.byKey(const Key('rail-room-1')));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });
}
