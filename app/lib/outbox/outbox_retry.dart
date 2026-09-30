import '../conversation/message_store.dart';
import '../diagnostics/crash_reporting.dart';
import '../wire/message.dart';
import 'outbox_drain.dart';
import 'outbox_store.dart';

/// Re-send one failed outbox row when the user taps "tap to retry".
///
/// Flips the bubble back to `sending`, clears the drain's per-cycle dedup for
/// just this id (so it actually re-sends without a reconnect), and kicks the
/// drain. If the kick throws, the row MUST land back on `failed`: a stuck
/// `sending` row is deliberately not retryable (see `SendIssueCaption`), so
/// leaving it there would take the retry away from the user.
///
/// No-op when the outbox has no row for [clientMsgId] (already echoed or
/// cancelled).
Future<void> retryOutboxSend({
  required OutboxStore store,
  required OutboxDrain drain,
  required MessageStore Function(String roomId) messages,
  required String clientMsgId,
}) async {
  final row = await store.lookup(clientMsgId);
  if (row == null) return;
  await store.markAttempt(clientMsgId, reset: true);
  final msgs = messages(row.roomId);
  msgs.updateStatus(clientMsgId, SendStatus.sending);
  drain.resetCycle(clientMsgId: clientMsgId);
  try {
    await drain.kick();
  } catch (e, st) {
    msgs.updateStatus(clientMsgId, SendStatus.failed);
    reportFault(e, st, context: 'outbox_retry');
  }
}
