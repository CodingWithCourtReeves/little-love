import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/recording_overlay.dart';

void main() {
  testWidgets('overlay shows timer, cancel hint, and lock affordance', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingOverlay(
            elapsed: Duration(seconds: 5),
            locked: false,
            cancelArmed: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('recording-overlay')), findsOneWidget);
    expect(find.text('0:05'), findsOneWidget);
    expect(find.textContaining('slide to cancel'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('locked overlay shows stop + send', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RecordingOverlay(
            elapsed: Duration(seconds: 5),
            locked: true,
            cancelArmed: false,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('recording-stop')), findsOneWidget);
    expect(find.byKey(const Key('recording-send')), findsOneWidget);
  });

  test('formatElapsed renders m:ss', () {
    expect(formatElapsed(const Duration(seconds: 5)), '0:05');
    expect(formatElapsed(const Duration(seconds: 65)), '1:05');
    expect(formatElapsed(const Duration(minutes: 2, seconds: 9)), '2:09');
  });
}
