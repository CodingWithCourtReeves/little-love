import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_palette.dart';
import '../wire/live_connection.dart';

/// How long a send can show the in-flight clock before its run gets a caption
/// saying so. Long enough to cover a slow link-preview fetch (capped at 7s) plus
/// a reconnect, short enough that a stalled send doesn't look fine forever.
const stuckSendAfter = Duration(seconds: 20);

/// The one caption under a run of my messages that has a send problem: a
/// failed send, or one stuck in flight past [stuckSendAfter]. Tapping the
/// run's bubble retries it (handled by the page).
///
/// There is no delivery ACK besides the server's echo, and a send stays in the
/// persistent outbox until that echo arrives, so a stuck send is **not**
/// flipped to failed: it will still go out on its own. The copy says what is
/// actually happening instead. Offline, both cases just wait for the socket
/// (the outbox drains on reconnect).
///
/// Watches the connection itself (rather than the page doing it) so only a
/// run with a problem rebuilds when the socket flaps.
class SendIssueCaption extends ConsumerWidget {
  const SendIssueCaption({super.key, required this.failed});

  /// True when the run holds a failed send; false when it's only stuck.
  final bool failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectionUpProvider);
    final palette = context.palette;
    final (text, color) = switch ((online, failed)) {
      (false, _) => ('Waiting for connection', palette.textMuted),
      (true, true) => ("Couldn't send · tap to retry", palette.warningTone),
      (true, false) => ('Still sending · tap to retry', palette.textMuted),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 16, top: 2, bottom: 2),
      child: Text(
        text,
        key: const Key('send-issue-caption'),
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}
