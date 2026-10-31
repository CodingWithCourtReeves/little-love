import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_palette.dart';
import 'last_seen_label.dart';
import 'presence_state.dart';
import 'typing_state.dart';

/// The partner's status line: "typing" with gently pulsing dots while they
/// compose, otherwise their presence ("online", "last seen today at 9:41 PM",
/// "offline"). Empty when there's no partner (a solo room).
///
/// Shown under the room name in the chat's title pill and under the name on
/// the chat-info page. Living in the app bar (not as a list row) keeps the
/// partner's typing state from reflowing the message list, which otherwise
/// nudged the list on send.
class PartnerStatusLine extends ConsumerStatefulWidget {
  const PartnerStatusLine({
    super.key,
    required this.roomId,
    required this.partner,
    this.fontSize = 11,
    this.labelColor,
  });

  final String roomId;
  final String? partner;
  final double fontSize;

  /// Color for the words, where the default (sage online, muted offline) would
  /// fall short of 4.5:1, e.g. over the wallpaper on the chat-info page. The
  /// presence dot keeps its sage / muted tone either way.
  final Color? labelColor;

  @override
  ConsumerState<PartnerStatusLine> createState() => _PartnerStatusLineState();
}

class _PartnerStatusLineState extends ConsumerState<PartnerStatusLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Recompute the relative "last seen …" label once a minute so it advances
    // (e.g. "5 minutes ago" → "6 minutes ago") without any new network traffic.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = ref.watch(typingProvider(widget.roomId));
    if (typing) {
      return Row(
        key: const Key('typing-indicator'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'typing',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: widget.fontSize,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w500,
              color: widget.labelColor ?? context.palette.accentSage,
            ),
          ),
          const SizedBox(width: 5),
          const _PulsingDots(),
        ],
      );
    }
    if (widget.partner == null) return const SizedBox.shrink();
    final presence = ref.watch(presenceProvider(widget.partner!));
    final online = presence.online;
    final tone = online
        ? context.palette.accentSage
        : context.palette.textMuted;

    final String label;
    if (online) {
      label = 'online';
    } else if (presence.lastSeen != null) {
      label = lastSeenLabel(
        presence.lastSeen!,
        now: DateTime.now(),
        use24h: MediaQuery.alwaysUse24HourFormatOf(context),
      );
    } else {
      label = 'offline';
    }

    return Row(
      key: const Key('presence-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: widget.fontSize * 6 / 11,
          height: widget.fontSize * 6 / 11,
          decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
        ),
        const SizedBox(width: 5),
        // Flexible + ellipsis: a long "last seen Wednesday at 12:59 PM" at a
        // large text size truncates inside the title pill instead of
        // overflowing it.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: widget.fontSize,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w500,
              color: widget.labelColor ?? tone,
            ),
          ),
        ),
      ],
    );
  }
}

/// Three sage dots whose opacity pulses in a gentle staggered wave (no bounce).
class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Opacity(
                  // Staggered sine pulse: each dot fades out of phase, 0.25→1.
                  opacity:
                      (0.25 +
                              0.75 *
                                  math.sin(
                                    ((_c.value + i * 0.2) % 1.0) * math.pi,
                                  ))
                          .clamp(0.0, 1.0),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: context.palette.accentSage,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
