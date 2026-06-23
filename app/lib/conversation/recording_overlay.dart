import 'package:flutter/material.dart';

/// Format a duration as `m:ss` (e.g. `1:05`). Shared by the recording overlay
/// and the playback bubble.
String formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The composer replacement shown while a voice memo is recording. Pure
/// presentation — the gesture/state machine lives in the conversation page.
class RecordingOverlay extends StatelessWidget {
  const RecordingOverlay({
    super.key,
    required this.elapsed,
    required this.locked,
    required this.cancelArmed,
    this.onStop,
    this.onSend,
  });

  final Duration elapsed;
  final bool locked;
  final bool cancelArmed;
  final VoidCallback? onStop;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('recording-overlay'),
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.circle, color: Colors.red, size: 12),
          const SizedBox(width: 10),
          Text(formatElapsed(elapsed)),
          const Spacer(),
          if (locked) ...[
            IconButton(
              key: const Key('recording-stop'),
              icon: const Icon(Icons.delete_outline),
              onPressed: onStop,
            ),
            IconButton(
              key: const Key('recording-send'),
              icon: const Icon(Icons.arrow_upward),
              onPressed: onSend,
            ),
          ] else ...[
            Opacity(
              opacity: cancelArmed ? 1.0 : 0.6,
              child: const Text('‹ slide to cancel'),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.lock_outline, size: 18),
          ],
        ],
      ),
    );
  }
}
