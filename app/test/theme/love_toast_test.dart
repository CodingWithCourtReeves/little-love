import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/love_toast.dart';

void main() {
  testWidgets('showLoveToast shows the message, then auto-dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    showLoveToast(context, 'Copied', icon: Icons.check),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // insert the overlay entry
    await tester.pump(const Duration(milliseconds: 260)); // slide + fade in
    expect(find.text('Copied'), findsOneWidget);

    // Holds ~1.5s, then fades out and removes itself.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsNothing);
  });
}
