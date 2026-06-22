import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/theme/palette_provider.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors the app root: theme follows the wallpaper's brightness, and a
/// descendant reports whichever theme it actually resolved.
class _ThemeProbe extends ConsumerWidget {
  const _ThemeProbe();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(paletteProvider);
    return MaterialApp(
      theme: buildAppTheme(palette),
      home: Builder(
        builder: (c) => Text(
          Theme.of(c).brightness == Brightness.dark ? 'DARK' : 'LIGHT',
          textDirection: TextDirection.ltr,
        ),
      ),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the whole app theme follows the wallpaper brightness', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const _ThemeProbe(),
      ),
    );
    await tester.pumpAndSettle();

    // Default wallpaper is Twilight (dark), so the app boots dark.
    expect(find.text('DARK'), findsOneWidget);

    // Switch to a light wallpaper → the whole theme flips to light.
    await container
        .read(wallpaperControllerProvider.notifier)
        .setGradient(WallpaperGradient.rose);
    await tester.pumpAndSettle();
    expect(find.text('LIGHT'), findsOneWidget);

    // And back to a dark one.
    await container
        .read(wallpaperControllerProvider.notifier)
        .setGradient(WallpaperGradient.deepDusk);
    await tester.pumpAndSettle();
    expect(find.text('DARK'), findsOneWidget);
  });
}
