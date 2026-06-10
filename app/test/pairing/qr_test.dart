import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/qr.dart';

void main() {
  testWidgets('InviteQr renders without throwing for a valid code', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: InviteQr(code: 'amber-fern-locket-tide', size: 200),
          ),
        ),
      ),
    );
    expect(find.byType(InviteQr), findsOneWidget);
  });
}
