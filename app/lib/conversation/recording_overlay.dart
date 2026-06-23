import 'package:flutter/material.dart';

/// Format a duration as `m:ss` (e.g. `1:05`). Shared by the recording strip and
/// the playback bubble.
String formatElapsed(Duration d) {
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// The recording UI shown *inside* the composer pill (the chat bar stays put;
/// only its content swaps). Red dot + running timer + a live waveform, plus a
/// slide-to-cancel hint while held, or a trash button once locked hands-free.
class RecordingStrip extends StatelessWidget {
  const RecordingStrip({
    super.key,
    required this.elapsed,
    required this.locked,
    required this.cancelArmed,
    required this.waveform,
    required this.barColor,
    required this.hintColor,
    this.onTrash,
  });

  final Duration elapsed;
  final bool locked;
  final bool cancelArmed;

  /// Live amplitude peaks (0..31), newest last.
  final List<int> waveform;
  final Color barColor;
  final Color hintColor;
  final VoidCallback? onTrash;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('recording-strip'),
      height: 44,
      child: Row(
        children: [
          if (locked)
            IconButton(
              key: const Key('recording-trash'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline, color: hintColor, size: 22),
              onPressed: onTrash,
            )
          else
            const SizedBox(width: 14),
          const Icon(Icons.circle, color: Colors.red, size: 11),
          const SizedBox(width: 8),
          Text(
            formatElapsed(elapsed),
            style: TextStyle(
              color: barColor,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LiveWaveform(peaks: waveform, color: barColor),
          ),
          const SizedBox(width: 10),
          if (!locked)
            Text(
              cancelArmed ? 'release to cancel' : '‹ slide to cancel',
              style: TextStyle(
                color: cancelArmed ? Colors.red : hintColor,
                fontSize: 12,
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// A live recording waveform: amplitude peaks drawn as centred bars, newest on
/// the right so it reads as scrolling while you speak.
class LiveWaveform extends StatelessWidget {
  const LiveWaveform({super.key, required this.peaks, required this.color});
  final List<int> peaks;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('recording-waveform'),
      height: 28,
      child: CustomPaint(
        size: Size.infinite,
        painter: _LiveWaveformPainter(peaks: peaks, color: color),
      ),
    );
  }
}

class _LiveWaveformPainter extends CustomPainter {
  _LiveWaveformPainter({required this.peaks, required this.color});
  final List<int> peaks;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    const gap = 3.0;
    final barW = 2.0;
    final slot = barW + gap;
    final maxBars = (size.width / slot).floor();
    // Draw the most recent peaks, right-aligned so it scrolls leftward.
    final shown = peaks.length > maxBars
        ? peaks.sublist(peaks.length - maxBars)
        : peaks;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barW;
    final startX = size.width - shown.length * slot;
    for (var i = 0; i < shown.length; i++) {
      final x = startX + i * slot + barW / 2;
      final h = (shown[i] / 31.0) * size.height;
      final half = (h < 2 ? 2 : h) / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 - half),
        Offset(x, size.height / 2 + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LiveWaveformPainter old) =>
      old.peaks != peaks || old.color != color;
}
