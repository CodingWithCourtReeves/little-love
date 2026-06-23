import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_log.dart';
import 'package:littlelove/calling/call_state.dart';
import 'package:littlelove/conversation/message_content.dart';

void main() {
  test('buildCallLog → encode → decode round-trips', () {
    final started = DateTime.utc(2026, 6, 23, 18, 30);
    final content = buildCallLog(
      callId: 'c1',
      outcome: CallOutcome.completed,
      duration: const Duration(minutes: 4, seconds: 32),
      startedAt: started,
    );

    final decoded = MessageContent.decode(content.encode());
    expect(decoded, isA<CallContent>());
    final call = decoded as CallContent;
    expect(call.callId, 'c1');
    expect(call.outcome, 'completed');
    expect(call.durationS, 272);
    expect(call.startedAt, started);
  });

  test('every CallOutcome maps to a distinct wire string', () {
    final wires = CallOutcome.values.map(outcomeToWire).toSet();
    expect(wires.length, CallOutcome.values.length);
    expect(outcomeToWire(CallOutcome.missed), 'missed');
    expect(outcomeToWire(CallOutcome.declined), 'declined');
  });

  test('decoding a missed call yields zero duration', () {
    final content = buildCallLog(
      callId: 'c2',
      outcome: CallOutcome.missed,
      duration: Duration.zero,
      startedAt: DateTime.utc(2026, 6, 23),
    );
    final call = MessageContent.decode(content.encode()) as CallContent;
    expect(call.outcome, 'missed');
    expect(call.durationS, 0);
  });

  test('non-call envelopes still decode as their own kind', () {
    // Guard: adding the call kind must not swallow other kinds or plain text.
    expect(MessageContent.decode('hello'), isA<TextContent>());
  });
}
