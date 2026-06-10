import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/layout_scaffold.dart';

Widget _harness({required double width}) {
  return ProviderScope(
    child: MaterialApp(
      home: Center(
        child: SizedBox(
          width: width,
          height: 900,
          child: const LayoutScaffold(
            sidebar: Text('SIDEBAR'),
            rail: Text('RAIL'),
            drawer: Text('DRAWER'),
            detail: Text('DETAIL'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders sidebar at 1400px wide', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_harness(width: 1400));
    expect(find.text('SIDEBAR'), findsOneWidget);
    expect(find.text('RAIL'), findsNothing);
    expect(find.text('DRAWER'), findsNothing);
    expect(find.text('DETAIL'), findsOneWidget);
  });

  testWidgets('renders rail at 700px wide', (tester) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_harness(width: 700));
    expect(find.text('RAIL'), findsOneWidget);
    expect(find.text('SIDEBAR'), findsNothing);
    expect(find.text('DRAWER'), findsNothing);
    expect(find.text('DETAIL'), findsOneWidget);
  });

  testWidgets('renders drawer scaffold at 500px wide', (tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(_harness(width: 500));
    // Drawer chrome → Scaffold with detail in body. The DRAWER widget is
    // only mounted when the drawer is opened (Material behavior).
    expect(find.byType(Scaffold), findsWidgets);
    expect(find.text('DETAIL'), findsOneWidget);
    expect(find.text('SIDEBAR'), findsNothing);
    expect(find.text('RAIL'), findsNothing);
    // Drawer chrome is wired via Scaffold.hasDrawer (Material only mounts
    // the Drawer widget when opened).
    final ScaffoldState scaffoldState = tester.firstState(
      find.byType(Scaffold),
    );
    expect(scaffoldState.hasDrawer, isTrue);
    scaffoldState.openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('DRAWER'), findsOneWidget);
  });

  testWidgets(
    'resizing across sidebar↔rail boundary preserves detail Element identity',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const detailKey = ValueKey('detail-pane');
      Widget harness(double w) => ProviderScope(
        child: MaterialApp(
          home: Center(
            child: SizedBox(
              width: w,
              height: 900,
              child: LayoutScaffold(
                sidebar: const Text('SIDEBAR'),
                rail: const Text('RAIL'),
                drawer: const Text('DRAWER'),
                detail: const SizedBox(key: detailKey, child: Text('DETAIL')),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(harness(1200));
      final detailElement1 = tester.element(find.byKey(detailKey));
      await tester.pumpWidget(harness(700));
      final detailElement2 = tester.element(find.byKey(detailKey));
      // Same Element across the resize means Flutter reused the State —
      // no full remount of the conversation page.
      expect(identical(detailElement1, detailElement2), isTrue);
    },
  );
}
