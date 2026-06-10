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
}
