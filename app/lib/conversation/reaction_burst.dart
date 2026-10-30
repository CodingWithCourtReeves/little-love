import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A one-shot burst (#77): small copies of [emoji] float up from [child] and
/// fade, while [child] (when [popChild]) pops in with an overshoot. Used when a
/// reaction lands on a bubble, and (with [big]) when a love tap arrives.
///
/// Plays **at most once**. [onDone] fires when it finishes *or* when it is
/// disposed early (scrolled out of the list, room closed), so the caller drops
/// its entry and a rebuild of the row can never replay it.
///
/// The particles live in the [Overlay], following [child] through a
/// [LayerLink], so they draw above neighbouring bubbles (which paint later in
/// the list and would otherwise cover them) and track the row while it scrolls.
class ReactionBurst extends StatefulWidget {
  const ReactionBurst({
    super.key,
    required this.emoji,
    required this.onDone,
    required this.child,
    this.big = false,
    this.popChild = true,
  });

  final String emoji;
  final VoidCallback onDone;
  final Widget child;

  /// Love-tap size: particles fly 1.7× as far and draw 1.35× larger.
  final bool big;

  /// Scale [child] in from zero with an overshoot. Off for a love tap, whose
  /// row already pops in.
  final bool popChild;

  /// How long each particle flies.
  static const flight = Duration(milliseconds: 1150);

  /// The child's pop-in.
  static const pop = Duration(milliseconds: 380);

  @override
  State<ReactionBurst> createState() => _ReactionBurstState();
}

/// One particle's path, mirroring the design mock (#77): an offset from the
/// origin in logical px, a final rotation in degrees, a start delay and a font
/// size. Fanned upward so they rise away from the bubble.
class _Particle {
  const _Particle(this.dx, this.dy, this.degrees, this.delayMs, this.size);
  final double dx;
  final double dy;
  final double degrees;
  final int delayMs;
  final double size;
}

const _particles = <_Particle>[
  _Particle(-46, -70, -20, 0, 16),
  _Particle(-22, -98, 10, 40, 20),
  _Particle(4, -84, -6, 15, 15),
  _Particle(26, -106, 16, 70, 18),
  _Particle(48, -66, 24, 30, 14),
  _Particle(-10, -122, -12, 100, 13),
  _Particle(36, -40, 30, 55, 12),
  _Particle(-38, -36, -28, 85, 12),
];

/// Fast out, long glide: the particles leap off the bubble then drift.
const _flightCurve = Cubic(0.15, 0.75, 0.3, 1);

final int _maxDelayMs = _particles.map((p) => p.delayMs).reduce(math.max);

class _ReactionBurstState extends State<ReactionBurst>
    with SingleTickerProviderStateMixin {
  static final Duration _total =
      ReactionBurst.flight + Duration(milliseconds: _maxDelayMs);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _total,
  );
  final _link = LayerLink();
  OverlayEntry? _entry;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    // Inserting into the Overlay during this frame's build would mark it dirty
    // mid-build, so wait for the frame to land.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final overlay = Overlay.maybeOf(context);
      if (overlay != null) {
        _entry = OverlayEntry(builder: _buildParticles);
        overlay.insert(_entry!);
      }
      _c.forward();
    });
  }

  void _finish() {
    _entry?.remove();
    _entry = null;
    if (_done) return;
    _done = true;
    widget.onDone();
  }

  @override
  void dispose() {
    _finish();
    _c.dispose();
    super.dispose();
  }

  double get _elapsedMs => _c.value * _total.inMilliseconds;

  Widget _buildParticles(BuildContext context) {
    final k = widget.big ? 1.7 : 1.0;
    final sizeScale = widget.big ? 1.35 : 1.0;
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.center,
        followerAnchor: Alignment.center,
        child: IgnorePointer(
          key: const Key('reaction-burst-particles'),
          child: SizedBox(
            width: 1,
            height: 1,
            // Text in the Overlay has no Material ancestor; without this it
            // picks up the yellow debug underline.
            child: DefaultTextStyle(
              style: const TextStyle(decoration: TextDecoration.none),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final p in _particles)
                      _particle(p, k: k, sizeScale: sizeScale),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _particle(
    _Particle p, {
    required double k,
    required double sizeScale,
  }) {
    final t = ((_elapsedMs - p.delayMs) / ReactionBurst.flight.inMilliseconds)
        .clamp(0.0, 1.0);
    final eased = _flightCurve.transform(t);
    // Fade in fast, hold, then fade out over the last 30% of the flight.
    final opacity = t < 0.14
        ? t / 0.14
        : t < 0.7
        ? 1.0 - 0.1 * (t - 0.14) / 0.56
        : 0.9 * (1 - (t - 0.7) / 0.3);
    final size = p.size * sizeScale;
    return Positioned(
      left: p.dx * k * eased - size / 2,
      top: p.dy * k * eased - size / 2,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: p.degrees * eased * math.pi / 180,
          child: Transform.scale(
            scale: 0.3 + 0.7 * eased,
            child: Text(
              widget.emoji,
              style: TextStyle(fontSize: size, height: 1.0),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.popChild
        ? AnimatedBuilder(
            animation: _c,
            builder: (context, child) {
              final t = (_elapsedMs / ReactionBurst.pop.inMilliseconds).clamp(
                0.0,
                1.0,
              );
              return Transform.scale(
                scale: Curves.easeOutBack.transform(t),
                child: child,
              );
            },
            child: widget.child,
          )
        : widget.child;
    return CompositedTransformTarget(link: _link, child: child);
  }
}
