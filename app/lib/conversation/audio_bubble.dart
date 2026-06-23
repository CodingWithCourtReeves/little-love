import 'package:flutter/material.dart';

import '../attachment/attachment_descriptor.dart';
import '../audio/playback_controller.dart';
import '../theme/app_palette.dart';
import '../wire/live_connection.dart';
import 'recording_overlay.dart' show formatElapsed;

/// Renders a voice memo: play/pause, a tappable+scrubbable bar waveform with a
/// progress fill, elapsed/total time, and a playback-speed badge. Playback is
/// owned by the shared [VoicePlaybackController] so only one memo plays at a
/// time.
class AudioBubble extends StatelessWidget {
  const AudioBubble({
    super.key,
    required this.descriptor,
    required this.isMe,
    required this.controller,
    required this.conn,
  });

  final AttachmentDescriptor descriptor;
  final bool isMe;
  final VoicePlaybackController controller;
  final LiveConnection? conn;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final active = controller.activeBlobKey == descriptor.blobKey;
        final playing = active && controller.isPlaying;
        final total = Duration(milliseconds: descriptor.durationMs ?? 0);
        final progress = (active && total.inMilliseconds > 0)
            ? controller.position.inMilliseconds / total.inMilliseconds
            : 0.0;
        // Match the enclosing bubble's text colour so the controls/waveform
        // read on both palettes (the "mine" bubble is light pink in light mode,
        // so white would vanish).
        final fg = isMe
            ? context.palette.bubbleUserText
            : context.palette.textPrimary;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const Key('audio-play'),
                color: fg,
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                onPressed: conn == null
                    ? null
                    : () => controller.toggle(descriptor, conn),
              ),
              _Waveform(
                peaks: descriptor.waveform ?? const [],
                progress: progress.clamp(0.0, 1.0),
                color: fg,
                onSeekFraction: (frac) {
                  if (active && total > Duration.zero) {
                    controller.seek(total * frac);
                  }
                },
              ),
              const SizedBox(width: 8),
              Text(
                formatElapsed(active ? controller.position : total),
                style: TextStyle(color: fg, fontSize: 12),
              ),
              const SizedBox(width: 8),
              if (active)
                GestureDetector(
                  key: const Key('audio-speed'),
                  onTap: controller.cycleSpeed,
                  child: Text(
                    '${_fmtSpeed(controller.speed)}×',
                    style: TextStyle(color: fg, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _fmtSpeed(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1);
}

class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.peaks,
    required this.progress,
    required this.color,
    required this.onSeekFraction,
  });

  final List<int> peaks;
  final double progress;
  final Color color;
  final ValueChanged<double> onSeekFraction;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        onSeekFraction((d.localPosition.dx / box.size.width).clamp(0.0, 1.0));
      },
      onTapDown: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        onSeekFraction((d.localPosition.dx / box.size.width).clamp(0.0, 1.0));
      },
      child: SizedBox(
        key: const Key('audio-waveform'),
        width: 160,
        height: 32,
        child: CustomPaint(
          painter: _WaveformPainter(
            peaks: peaks,
            progress: progress,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.color,
  });
  final List<int> peaks;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final barW = size.width / (peaks.length * 1.5);
    final played = color;
    final unplayed = color.withValues(alpha: 0.35);
    for (var i = 0; i < peaks.length; i++) {
      final x = i * 1.5 * barW;
      final h = (peaks[i] / 31.0) * size.height;
      final paint = Paint()
        ..color = (i / peaks.length) <= progress ? played : unplayed;
      final top = (size.height - h) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barW, h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.peaks != peaks;
}
