import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/drawer.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/twilight.dart';

Room _r(String id, String peer) => Room(
  roomId: id,
  peerUsername: peer,
  peerEd25519PubBase64: 'AAA',
  peerX25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 9),
);

void main() {
  testWidgets(
    'tapping a drawer entry updates selection and closes the drawer',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(inboxStateProvider.notifier).setRooms([
        _r('1', 'kaitlyn'),
      ]);
      final scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTwilightTheme(),
            home: Scaffold(
              key: scaffoldKey,
              appBar: AppBar(),
              drawer: const Drawer(child: DrawerContent(username: 'court')),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      );
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('drawer-room-1')));
      await tester.pumpAndSettle();

      expect(container.read(inboxStateProvider).selectedRoomId, '1');
      // Drawer is dismissed.
      expect(find.byKey(const Key('drawer-room-1')), findsNothing);
    },
  );
}
