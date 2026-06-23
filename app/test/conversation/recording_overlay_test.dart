import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/recording_overlay.dart';

RecordingStrip _strip({required bool locked, bool cancelArmed = false}) =>
    RecordingStrip(
      elapsed: const Duration(seconds: 5),
      locked: locked,
      cancelArmed: cancelArmed,
      waveform: List<int>.filled(20, 12),
      barColor: Colors.black,
      hintColor: Colors.grey,
    );

void main() {
  testWidgets('held strip shows timer, live waveform, and cancel hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _strip(locked: false))),
    );
    expect(find.byKey(const Key('recording-strip')), findsOneWidget);
    expect(find.byKey(const Key('recording-waveform')), findsOneWidget);
    expect(find.text('0:05'), findsOneWidget);
    expect(find.textContaining('slide to cancel'), findsOneWidget);
    expect(find.byKey(const Key('recording-trash')), findsNothing);
  });

  testWidgets('locked strip shows a trash button and no cancel hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _strip(locked: true))),
    );
    expect(find.byKey(const Key('recording-trash')), findsOneWidget);
    expect(find.textContaining('slide to cancel'), findsNothing);
  });

  test('formatElapsed renders m:ss', () {
    expect(formatElapsed(const Duration(seconds: 5)), '0:05');
    expect(formatElapsed(const Duration(seconds: 65)), '1:05');
    expect(formatElapsed(const Duration(minutes: 2, seconds: 9)), '2:09');
  });
}
