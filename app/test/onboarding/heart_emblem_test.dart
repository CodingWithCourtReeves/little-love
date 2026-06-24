import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/onboarding/heart_emblem.dart';
import 'package:littlelove/theme/app_palette.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('HeartEmblem builds under $brightness', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(AppPalette.of(brightness)),
          home: const Scaffold(body: Center(child: HeartEmblem())),
        ),
      );
      expect(find.byType(HeartEmblem), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
