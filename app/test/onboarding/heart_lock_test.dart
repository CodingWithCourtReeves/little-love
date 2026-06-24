import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/onboarding/heart_lock.dart';
import 'package:littlelove/theme/app_palette.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('HeartLock builds and settles under $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppPalette.of(brightness)),
          home: const Scaffold(body: Center(child: HeartLock())),
        ),
      );
      // Let the entrance tween run to completion.
      await tester.pumpAndSettle();
      expect(find.byType(HeartLock), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
