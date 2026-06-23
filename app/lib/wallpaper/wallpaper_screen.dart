import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_palette.dart';
import 'wallpaper_picker.dart';

class WallpaperScreen extends ConsumerWidget {
  const WallpaperScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const WallpaperScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        elevation: 0,
        title: const Text('Wallpaper'),
      ),
      body: const SingleChildScrollView(
        child: WallpaperPicker(padding: EdgeInsets.all(16)),
      ),
    );
  }
}
