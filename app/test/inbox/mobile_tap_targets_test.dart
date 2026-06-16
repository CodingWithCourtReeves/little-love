import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/drawer.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/navigation_rail.dart';
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

void _assertMin(WidgetTester tester, Key key) {
  final s = tester.getSize(find.byKey(key));
  expect(
    s.width,
    greaterThanOrEqualTo(44),
    reason: 'tap target for $key must be >= 44 wide; got ${s.width}',
  );
  expect(
    s.height,
    greaterThanOrEqualTo(44),
    reason: 'tap target for $key must be >= 44 tall; got ${s.height}',
  );
}

void main() {
  testWidgets('sidebar room tile is >= 44x44', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: const Scaffold(
            body: SizedBox(width: 240, child: Sidebar(username: 'court')),
          ),
        ),
      ),
    );
    _assertMin(tester, const Key('room-1'));
    _assertMin(tester, const Key('sidebar-settings'));
  });

  testWidgets('rail tile is >= 44x44', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'k')]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: const Scaffold(body: NavigationRailChrome()),
        ),
      ),
    );
    _assertMin(tester, const Key('rail-room-1'));
  });

  testWidgets('drawer room tile is >= 44x44', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
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
    _assertMin(tester, const Key('drawer-room-1'));
  });
}
