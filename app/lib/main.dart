import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'calling/call_screen.dart';
import 'conversation/incoming_banner_host.dart';
import 'identity/dev_provision.dart';
import 'inbox/mock_fixtures.dart';
import 'screens/auth/auth_gate.dart';
import 'theme/app_palette.dart';
import 'theme/palette_provider.dart';

const _fixtures = String.fromEnvironment('LLOVE_FIXTURES', defaultValue: '');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  if (_fixtures == 'demo') {
    seedDemoFixtures(container);
  }
  // Dev-only: adopt a seeded identity from runtime env when the two-simulator
  // harness sets it. No-op in production (env vars unset). See provisionDevIdentity.
  await provisionDevIdentity(container);
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
      // Float the in-app call UI and the cross-room "new message" banner above
      // every route. CallOverlay shows the same call screen on both caller and
      // callee (CallKit owns the ring + system UI) and is transparent /
      // pointer-passthrough until a call is live; IncomingBannerHost slides a
      // banner down when a partner messages a room you're not viewing.
      // StackFit.expand gives the wrapped content tight fill constraints —
      // without it the Scaffold gets unbounded height and its body collapses
      // (black screen under the app bar).
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          IncomingBannerHost(child: child ?? const SizedBox.shrink()),
          const CallOverlay(),
        ],
      ),
      home: const AuthGate(),
    );
  }
}
