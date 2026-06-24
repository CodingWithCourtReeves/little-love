import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/incoming_banner_host.dart';
import 'package:littlelove/conversation/incoming_banner_provider.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/theme/app_palette.dart';

const _banner = IncomingBanner(
  roomId: 'room-b',
  roomName: 'Date ideas',
  preview: 'pick a restaurant?',
  msgId: 'm1',
);

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: const IncomingBannerHost(child: Scaffold(body: SizedBox())),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('shows a banner with room name + preview on a new event', (
    tester,
  ) async {
    final container = await _pump(tester);
    // Nothing showing initially.
    expect(find.byKey(const Key('incoming-banner')), findsNothing);

    // ref.listen fires on change, so set the event AFTER the first frame.
    container.read(incomingBannerProvider.notifier).show(_banner);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('incoming-banner')), findsOneWidget);
    expect(find.text('Date ideas'), findsOneWidget);
    expect(find.text('pick a restaurant?'), findsOneWidget);
  });

  testWidgets('tapping requests the room and clears the banner', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(incomingBannerProvider.notifier).show(_banner);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('incoming-banner')));
    await tester.pumpAndSettle();

    // Reuses the deep-link path: HomeScreen will push this room.
    expect(container.read(requestedRoomProvider), 'room-b');
    // Banner cleared + slid away.
    expect(container.read(incomingBannerProvider), isNull);
    expect(find.byKey(const Key('incoming-banner')), findsNothing);
  });

  testWidgets('auto-dismisses after its timeout', (tester) async {
    final container = await _pump(tester);
    container.read(incomingBannerProvider.notifier).show(_banner);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('incoming-banner')), findsOneWidget);

    // Past the 4s auto-dismiss window.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(container.read(incomingBannerProvider), isNull);
    expect(find.byKey(const Key('incoming-banner')), findsNothing);
  });
}
