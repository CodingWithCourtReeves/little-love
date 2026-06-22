import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_background.dart';

void main() {
  test('lerpAnchors interpolates element-wise', () {
    final out = lerpAnchors(
      const [Offset(0, 0), Offset(0, 0), Offset(0, 0), Offset(0, 0)],
      const [Offset(1, 1), Offset(2, 2), Offset(0, 0), Offset(0, 0)],
      0.5,
    );
    expect(out[0], const Offset(0.5, 0.5));
    expect(out[1], const Offset(1, 1));
    expect(out.length, 4);
  });

  testWidgets('renders child over a CustomPaint background', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: WallpaperBackground(
              child: const Text('hi', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ),
    );
    expect(find.text('hi'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
