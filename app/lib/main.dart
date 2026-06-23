import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'inbox/mock_fixtures.dart';
import 'screens/auth/auth_gate.dart';
import 'theme/app_palette.dart';
import 'theme/palette_provider.dart';

const _fixtures = String.fromEnvironment('LLOVE_FIXTURES', defaultValue: '');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  if (_fixtures == 'demo') {
    seedDemoFixtures(container);
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LittleLoveApp(),
    ),
  );
}

class LittleLoveApp extends ConsumerWidget {
  const LittleLoveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The active palette follows the wallpaper each user picks; MaterialApp
    // cross-fades the theme (and its AppPalette extension) when it changes.
    final palette = ref.watch(paletteProvider);
    return MaterialApp(
      title: 'LittleLove',
      theme: buildAppTheme(palette),
      home: const AuthGate(),
    );
  }
}
