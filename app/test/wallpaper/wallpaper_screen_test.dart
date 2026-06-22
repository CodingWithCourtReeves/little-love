import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_screen.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'shows four gradients + a doodles toggle; tapping updates selection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // Tall viewport so the grid + toggle fit without scrolling.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildAppTheme(AppPalette.light),
            home: const WallpaperScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final g in WallpaperGradient.values) {
        expect(find.text(g.label), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('wallpaper-rose')));
      await tester.pump();
      expect(
        container.read(wallpaperControllerProvider).gradient,
        WallpaperGradient.rose,
      );

      await tester.tap(find.byKey(const Key('wallpaper-doodles-toggle')));
      await tester.pump();
      expect(container.read(wallpaperControllerProvider).doodles, isFalse);
    },
  );
}
