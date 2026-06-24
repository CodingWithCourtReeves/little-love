import '../conversation/message_content.dart';
import 'call_state.dart';

/// The wire string for a [CallOutcome] (matches the `outcome` field of a
/// `call`-kind [MessageContent]).
String outcomeToWire(CallOutcome outcome) => switch (outcome) {
  CallOutcome.completed => 'completed',
  CallOutcome.missed => 'missed',
  CallOutcome.declined => 'declined',
  CallOutcome.cancelled => 'cancelled',
  CallOutcome.busy => 'busy',
  CallOutcome.failed => 'failed',
};

/// A short human-readable summary for a call-log timeline row, given the
/// `outcome` wire string and connected `durationS`. Pass [video] to label it a
/// video call. (A richer styled call bubble can replace this later; this keeps
/// the entry legible meanwhile.)
String callLogSummary(String outcome, int durationS, {bool video = false}) {
  final icon = video ? '📹' : '📞';
  final noun = video ? 'Video call' : 'Call';
  switch (outcome) {
    case 'completed':
      final mm = (durationS ~/ 60).toString();
      final ss = (durationS % 60).toString().padLeft(2, '0');
      return '$icon $noun · $mm:$ss';
    case 'missed':
      return '$icon Missed ${video ? 'video call' : 'call'}';
    case 'declined':
      return '$icon $noun declined';
    case 'cancelled':
      return '$icon Cancelled ${video ? 'video call' : 'call'}';
    case 'busy':
      return '$icon Busy';
    case 'failed':
      return '$icon $noun failed';
    default:
      return '$icon $noun';
  }
}

/// Build the call-log [MessageContent] for a finished call. The terminating
/// side encodes this and sends it through the normal outbox/Send path; both
/// partners receive it (the sender via its self-copy) and dedupe by [callId].
CallContent buildCallLog({
  required String callId,
  required CallOutcome outcome,
  required Duration duration,
  required DateTime startedAt,
  bool video = false,
}) {
  return CallContent(
    callId: callId,
    outcome: outcomeToWire(outcome),
    durationS: duration.inSeconds,
    startedAt: startedAt,
    video: video,
  );
}
