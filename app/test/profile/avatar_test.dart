import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/profile/avatar.dart';

void main() {
  testWidgets('shows the seed initial when no image', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Avatar(seedText: 'alice')),
      ),
    );
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('empty seed renders without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Avatar(seedText: '')),
      ),
    );
    expect(find.byType(Avatar), findsOneWidget);
  });
}
