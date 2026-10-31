import 'package:flutter_test/flutter_test.dart';

/// Pumps [step] at a time until [condition] holds, failing after [maxPumps].
///
/// The widget-test counterpart of `pumpUntil` (room_message_router_test.dart):
/// under testWidgets' fake clock each pump also advances timers (a search
/// debounce) and flushes in-process DB queries. Use it instead of
/// `pumpAndSettle` where a spinner or animation never settles.
Future<void> pumpUntilTrue(
  WidgetTester tester,
  bool Function() condition, {
  Duration step = const Duration(milliseconds: 50),
  int maxPumps = 100,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (condition()) return;
    await tester.pump(step);
  }
  if (!condition()) {
    throw StateError('pumpUntilTrue: condition not met after $maxPumps pumps');
  }
}

/// [pumpUntilTrue] for "this finder matches something".
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration step = const Duration(milliseconds: 50),
  int maxPumps = 100,
}) => pumpUntilTrue(
  tester,
  () => finder.evaluate().isNotEmpty,
  step: step,
  maxPumps: maxPumps,
);
