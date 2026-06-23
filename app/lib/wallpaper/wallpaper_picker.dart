import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_palette.dart';
import '../theme/twilight.dart';
import 'wallpaper_background.dart';
import 'wallpaper_controller.dart';
import 'wallpaper_selection.dart';

/// The gradient grid + doodles toggle, without a Scaffold/AppBar, so it can be
/// hosted both as a standalone screen ([WallpaperScreen]) and embedded as a
/// section of the profile screen. Reads/writes [wallpaperControllerProvider].
class WallpaperPicker extends ConsumerWidget {
  const WallpaperPicker({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(wallpaperControllerProvider);
    final controller = ref.read(wallpaperControllerProvider.notifier);

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.7,
            children: [
              for (final g in WallpaperGradient.values)
                _GradientTile(
                  gradient: g,
                  selected: selection.gradient == g,
                  onTap: () => controller.setGradient(g),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            key: const Key('wallpaper-doodles-toggle'),
            value: selection.doodles,
            onChanged: controller.setDoodles,
            title: const Text('Love Doodles'),
            subtitle: const Text('A subtle pattern over the gradient'),
            activeThumbColor: context.palette.accentUser,
          ),
        ],
      ),
    );
  }
}

class _GradientTile extends StatelessWidget {
  const _GradientTile({
    required this.gradient,
    required this.selected,
    required this.onTap,
  });
  final WallpaperGradient gradient;
  final bool selected;
  final VoidCallback onTap;

  String get _keySuffix => switch (gradient) {
    WallpaperGradient.rose => 'rose',
    WallpaperGradient.twilight => 'twilight',
    WallpaperGradient.mauveSage => 'sage',
    WallpaperGradient.deepDusk => 'deep',
  };

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('wallpaper-$_keySuffix'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? context.palette.accentUser
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                painter: WallpaperMeshPainter(
                  gradient: gradient,
                  anchors: const [
                    Offset(0.18, 0.18),
                    Offset(0.84, 0.24),
                    Offset(0.22, 0.86),
                    Offset(0.86, 0.80),
                  ],
                  doodles: false,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(gradient.label, style: TwilightType.body),
        ],
      ),
    );
  }
}
