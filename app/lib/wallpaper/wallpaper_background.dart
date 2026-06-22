import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'wallpaper_selection.dart';
import 'wallpaper_controller.dart';
import 'wallpaper_doodles.dart';

/// Element-wise interpolation of two 4-anchor configurations.
List<Offset> lerpAnchors(List<Offset> a, List<Offset> b, double t) => [
  for (var i = 0; i < 4; i++) Offset.lerp(a[i], b[i], t)!,
];

class WallpaperBackground extends ConsumerStatefulWidget {
  const WallpaperBackground({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<WallpaperBackground> createState() =>
      _WallpaperBackgroundState();
}

class _WallpaperBackgroundState extends ConsumerState<WallpaperBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  int _slot = 0;
  int _lastDrift = 0;

  @override
  void initState() {
    super.initState();
    _ctrl.value = 1; // resting at the current slot
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _advance() {
    _slot = (_slot + 1) % kWallpaperDriftSlots.length;
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(wallpaperControllerProvider);
    // React to a send: bump → advance one drift.
    ref.listen<int>(wallpaperDriftProvider, (prev, next) {
      if (next != _lastDrift) {
        _lastDrift = next;
        _advance();
      }
    });

    final from =
        kWallpaperDriftSlots[(_slot - 1 + kWallpaperDriftSlots.length) %
            kWallpaperDriftSlots.length];
    final to = kWallpaperDriftSlots[_slot];

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final anchors = lerpAnchors(
          from,
          to,
          Curves.easeInOut.transform(_ctrl.value),
        );
        return CustomPaint(
          painter: WallpaperMeshPainter(
            gradient: selection.gradient,
            anchors: anchors,
            doodles: selection.doodles,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Paints the four-color radial mesh: base fill + four soft radial blobs at
/// the (unit-space) anchors, layered for a smooth blend.
class WallpaperMeshPainter extends CustomPainter {
  WallpaperMeshPainter({
    required this.gradient,
    required this.anchors,
    required this.doodles,
  });

  final WallpaperGradient gradient;
  final List<Offset> anchors;
  final bool doodles;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = gradient.base);

    final colors = gradient.colors;
    final radius = size.longestSide * 0.75;
    for (var i = 0; i < 4; i++) {
      final center = Offset(
        anchors[i].dx * size.width,
        anchors[i].dy * size.height,
      );
      final shader = RadialGradient(
        colors: [colors[i], colors[i].withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, Paint()..shader = shader);
    }

    if (doodles) {
      paintDoodleField(canvas, size, gradient.doodleInk);
    }
  }

  @override
  bool shouldRepaint(WallpaperMeshPainter old) =>
      old.gradient != gradient ||
      old.anchors != anchors ||
      old.doodles != doodles;
}
