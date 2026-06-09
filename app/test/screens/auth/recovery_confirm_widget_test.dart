import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/screens/auth/recovery_confirm.dart';

void main() {
  final phrase = List<String>.generate(12, (i) => 'w${i + 1}').join(' ');

  testWidgets('shows three labelled inputs and a disabled Confirm button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecoveryConfirmScreen(phrase: phrase, onConfirmed: () {}),
      ),
    );
    expect(find.text('Word 3'), findsOneWidget);
    expect(find.text('Word 7'), findsOneWidget);
    expect(find.text('Word 11'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('typing all three correct words enables Confirm', (tester) async {
    var fired = false;
    await tester.pumpWidget(
      MaterialApp(
        home: RecoveryConfirmScreen(
          phrase: phrase,
          onConfirmed: () => fired = true,
        ),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'w3');
    await tester.enterText(fields.at(1), 'w7');
    await tester.enterText(fields.at(2), 'w11');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(fired, isTrue);
  });

  testWidgets('wrong word surfaces an error and onConfirmed is not called', (
    tester,
  ) async {
    var fired = false;
    await tester.pumpWidget(
      MaterialApp(
        home: RecoveryConfirmScreen(
          phrase: phrase,
          onConfirmed: () => fired = true,
        ),
      ),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'w3');
    await tester.enterText(fields.at(1), 'WRONG');
    await tester.enterText(fields.at(2), 'w11');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(fired, isFalse);
    expect(find.textContaining('does not match'), findsOneWidget);
  });
}
