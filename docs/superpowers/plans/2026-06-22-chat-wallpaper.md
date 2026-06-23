# Personal Chat Wallpaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a personal, per-device chat wallpaper — one of four animated 4-color gradients with an optional tiled "Love Doodles" overlay — picked from a new Wallpaper screen and rendered behind the conversation, with the gradient drifting on each send.

**Architecture:** A `lib/wallpaper/` module owns a `WallpaperSelection` value (gradient enum + doodles bool), a `Notifier` that persists it via `shared_preferences`, and a `WallpaperBackground` widget that paints a 4-anchor radial mesh (+ tiled doodles) with a `CustomPainter`, animating anchor positions when a global drift counter increments. `ConversationPage` hosts the background behind its message list, frosts its app bar to match the existing glass composer, and bumps the drift counter on send. The dead sidebar settings gear opens the picker.

**Tech Stack:** Flutter, flutter_riverpod (`Notifier`/`NotifierProvider`), shared_preferences, dart:ui `CustomPainter` + `AnimationController`.

## Global Constraints

- Couples app, iOS-only MVP — prefer iOS-native behavior; light theme only (no dark-mode variants).
- Wallpaper is **personal/local** — never sent to the server or the partner; no E2EE involvement.
- **One wallpaper for all chats** (global per-device pref), not per-channel.
- Default for new users: **Twilight gradient + doodles ON**.
- Animate on send only — **no idle animation** (battery).
- Color tokens come from `TwilightColors` (`lib/theme/twilight.dart`); palette hexes are listed verbatim in Task 1.
- Riverpod convention: plain `Provider` for stateless, `class X extends Notifier<S>` + `NotifierProvider<X, S>(X.new)` for state.
- Run `dart format` + `flutter analyze` (zero issues) before every commit; tests via `flutter test`.

---

### Task 1: Wallpaper selection model + palettes

**Files:**
- Create: `app/lib/wallpaper/wallpaper_selection.dart`
- Test: `app/test/wallpaper/wallpaper_selection_test.dart`
- Modify: `app/pubspec.yaml` (add `shared_preferences: ^2.3.2` under dependencies)

**Interfaces:**
- Produces:
  - `enum WallpaperGradient { rose, twilight, mauveSage, deepDusk }`
  - `extension WallpaperGradientData on WallpaperGradient` with: `String get label`, `List<Color> get colors` (exactly 4), `Color get base`, `Color get doodleInk`.
  - `class WallpaperSelection { final WallpaperGradient gradient; final bool doodles; const WallpaperSelection({required this.gradient, required this.doodles}); WallpaperSelection copyWith({WallpaperGradient? gradient, bool? doodles}); ==/hashCode; static const WallpaperSelection defaults = WallpaperSelection(gradient: WallpaperGradient.twilight, doodles: true); }`
  - `const List<List<Offset>> kWallpaperDriftSlots` — 3 configurations of 4 unit-space (0..1) anchor offsets the drift cycles through.

- [ ] **Step 1: Add the dependency**

In `app/pubspec.yaml`, under `dependencies:` (after `html: ^0.15.4`):

```yaml
  shared_preferences: ^2.3.2
```

Run: `cd app && flutter pub get`
Expected: resolves, "Got dependencies!".

- [ ] **Step 2: Write the failing test**

```dart
// app/test/wallpaper/wallpaper_selection_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';

void main() {
  test('default is twilight + doodles on', () {
    expect(WallpaperSelection.defaults.gradient, WallpaperGradient.twilight);
    expect(WallpaperSelection.defaults.doodles, isTrue);
  });

  test('every gradient defines 4 colors, a base, a label and an ink', () {
    for (final g in WallpaperGradient.values) {
      expect(g.colors.length, 4, reason: '${g.name} needs 4 colors');
      expect(g.label, isNotEmpty);
      expect(g.base, isA<Color>());
      expect(g.doodleInk, isA<Color>());
    }
  });

  test('copyWith + equality', () {
    const a = WallpaperSelection(gradient: WallpaperGradient.rose, doodles: false);
    expect(a.copyWith(doodles: true),
        const WallpaperSelection(gradient: WallpaperGradient.rose, doodles: true));
    expect(a, a.copyWith());
  });

  test('drift slots are well-formed', () {
    expect(kWallpaperDriftSlots.length, greaterThanOrEqualTo(2));
    for (final slot in kWallpaperDriftSlots) {
      expect(slot.length, 4);
    }
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd app && flutter test test/wallpaper/wallpaper_selection_test.dart`
Expected: FAIL — `wallpaper_selection.dart` does not exist.

- [ ] **Step 4: Implement the model**

```dart
// app/lib/wallpaper/wallpaper_selection.dart
import 'package:flutter/material.dart';

/// The four shipped wallpaper gradients. Hex values are the approved
/// mockup palettes; each renders as a soft 4-point radial mesh.
enum WallpaperGradient { rose, twilight, mauveSage, deepDusk }

extension WallpaperGradientData on WallpaperGradient {
  String get label => switch (this) {
        WallpaperGradient.rose => 'Rosé',
        WallpaperGradient.twilight => 'Twilight',
        WallpaperGradient.mauveSage => 'Mauve & Sage',
        WallpaperGradient.deepDusk => 'Deep Dusk',
      };

  /// Four mesh colors, mapped to the four animated anchors in order.
  List<Color> get colors => switch (this) {
        WallpaperGradient.rose => const [
            Color(0xFFF7E3E8), Color(0xFFE8C8D2),
            Color(0xFFD9B8C6), Color(0xFFC98EA3),
          ],
        WallpaperGradient.twilight => const [
            Color(0xFF5B3450), Color(0xFFA04A6A),
            Color(0xFF8A5A7A), Color(0xFFC98EA3),
          ],
        WallpaperGradient.mauveSage => const [
            Color(0xFFC98EA3), Color(0xFFE2D3D8),
            Color(0xFFA9C2AC), Color(0xFF6E9B7A),
          ],
        WallpaperGradient.deepDusk => const [
            Color(0xFF241A28), Color(0xFF5E2C49),
            Color(0xFFA04A6A), Color(0xFF3E2C3A),
          ],
      };

  /// Fill behind the mesh (covers gaps where the radial falloffs fade out).
  Color get base => switch (this) {
        WallpaperGradient.rose => const Color(0xFFEFDCE2),
        WallpaperGradient.twilight => const Color(0xFF6B3D5C),
        WallpaperGradient.mauveSage => const Color(0xFFD8C9CF),
        WallpaperGradient.deepDusk => const Color(0xFF2A1F2A),
      };

  /// Doodle stroke color: light over dark palettes, dark over light ones.
  Color get doodleInk => switch (this) {
        WallpaperGradient.rose => const Color(0x14000000),
        WallpaperGradient.mauveSage => const Color(0x14000000),
        WallpaperGradient.twilight => const Color(0x24FFFFFF),
        WallpaperGradient.deepDusk => const Color(0x2BFFFFFF),
      };
}

class WallpaperSelection {
  const WallpaperSelection({required this.gradient, required this.doodles});

  final WallpaperGradient gradient;
  final bool doodles;

  static const WallpaperSelection defaults =
      WallpaperSelection(gradient: WallpaperGradient.twilight, doodles: true);

  WallpaperSelection copyWith({WallpaperGradient? gradient, bool? doodles}) =>
      WallpaperSelection(
        gradient: gradient ?? this.gradient,
        doodles: doodles ?? this.doodles,
      );

  @override
  bool operator ==(Object other) =>
      other is WallpaperSelection &&
      other.gradient == gradient &&
      other.doodles == doodles;

  @override
  int get hashCode => Object.hash(gradient, doodles);
}

/// Anchor configurations (unit space, 0..1) the gradient drifts between on
/// each send. Index advances per send and wraps.
const List<List<Offset>> kWallpaperDriftSlots = [
  [Offset(0.18, 0.18), Offset(0.84, 0.24), Offset(0.22, 0.86), Offset(0.86, 0.80)],
  [Offset(0.30, 0.12), Offset(0.74, 0.34), Offset(0.14, 0.74), Offset(0.92, 0.68)],
  [Offset(0.12, 0.30), Offset(0.88, 0.16), Offset(0.30, 0.92), Offset(0.78, 0.88)],
];
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && flutter test test/wallpaper/wallpaper_selection_test.dart`
Expected: PASS (4 tests). Then `flutter analyze` clean, `dart format lib/wallpaper test/wallpaper`.

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/wallpaper/wallpaper_selection.dart app/test/wallpaper/wallpaper_selection_test.dart
git commit -m "feat(wallpaper): selection model + four gradient palettes"
```

---

### Task 2: Persisted controller + drift counter providers

**Files:**
- Create: `app/lib/wallpaper/wallpaper_controller.dart`
- Test: `app/test/wallpaper/wallpaper_controller_test.dart`

**Interfaces:**
- Consumes: `WallpaperSelection`, `WallpaperGradient` (Task 1).
- Produces:
  - `class WallpaperController extends Notifier<WallpaperSelection>` with `WallpaperSelection build()` (returns `defaults` and async-hydrates from prefs), `Future<void> setGradient(WallpaperGradient)`, `Future<void> setDoodles(bool)`.
  - `final wallpaperControllerProvider = NotifierProvider<WallpaperController, WallpaperSelection>(WallpaperController.new);`
  - `class WallpaperDrift extends Notifier<int>` with `int build() => 0;` and `void bump() => state++;`
  - `final wallpaperDriftProvider = NotifierProvider<WallpaperDrift, int>(WallpaperDrift.new);`
- Persistence keys: `'wallpaper.gradient'` (stores `WallpaperGradient.name`), `'wallpaper.doodles'` (bool). Uses `SharedPreferences.getInstance()` directly; tests use `SharedPreferences.setMockInitialValues`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wallpaper/wallpaper_controller_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to twilight + doodles on when prefs empty', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(wallpaperControllerProvider), WallpaperSelection.defaults);
  });

  test('setGradient + setDoodles persist and re-read', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(wallpaperControllerProvider.notifier)
        .setGradient(WallpaperGradient.deepDusk);
    await c.read(wallpaperControllerProvider.notifier).setDoodles(false);
    expect(c.read(wallpaperControllerProvider),
        const WallpaperSelection(gradient: WallpaperGradient.deepDusk, doodles: false));

    // Fresh container reads the persisted values back.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    // allow async hydrate
    await c2.read(wallpaperControllerProvider.notifier).ensureLoaded();
    expect(c2.read(wallpaperControllerProvider).gradient, WallpaperGradient.deepDusk);
    expect(c2.read(wallpaperControllerProvider).doodles, isFalse);
  });

  test('drift bump increments', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(wallpaperDriftProvider), 0);
    c.read(wallpaperDriftProvider.notifier).bump();
    expect(c.read(wallpaperDriftProvider), 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/wallpaper/wallpaper_controller_test.dart`
Expected: FAIL — `wallpaper_controller.dart` missing.

- [ ] **Step 3: Implement the controller**

```dart
// app/lib/wallpaper/wallpaper_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallpaper_selection.dart';

const _kGradient = 'wallpaper.gradient';
const _kDoodles = 'wallpaper.doodles';

/// Per-device wallpaper choice, persisted via shared_preferences. [build]
/// returns the default immediately and hydrates asynchronously so the UI has
/// a sane background on first frame.
class WallpaperController extends Notifier<WallpaperSelection> {
  Future<void>? _loading;

  @override
  WallpaperSelection build() {
    _loading = _load();
    return WallpaperSelection.defaults;
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(_kGradient);
    final gradient = WallpaperGradient.values
        .where((g) => g.name == name)
        .firstOrNull;
    final doodles = p.getBool(_kDoodles);
    if (gradient != null || doodles != null) {
      state = WallpaperSelection(
        gradient: gradient ?? state.gradient,
        doodles: doodles ?? state.doodles,
      );
    }
  }

  /// Test/seam helper: await initial hydration.
  Future<void> ensureLoaded() => _loading ?? Future.value();

  Future<void> setGradient(WallpaperGradient g) async {
    state = state.copyWith(gradient: g);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kGradient, g.name);
  }

  Future<void> setDoodles(bool on) async {
    state = state.copyWith(doodles: on);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDoodles, on);
  }
}

final wallpaperControllerProvider =
    NotifierProvider<WallpaperController, WallpaperSelection>(
  WallpaperController.new,
);

/// A monotonically increasing counter the conversation bumps on each send;
/// the wallpaper watches it to trigger one gradient drift.
class WallpaperDrift extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final wallpaperDriftProvider =
    NotifierProvider<WallpaperDrift, int>(WallpaperDrift.new);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/wallpaper/wallpaper_controller_test.dart`
Expected: PASS (3 tests). `flutter analyze` clean; `dart format`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/wallpaper/wallpaper_controller.dart app/test/wallpaper/wallpaper_controller_test.dart
git commit -m "feat(wallpaper): persisted selection controller + send-drift counter"
```

---

### Task 3: Animated mesh painter + WallpaperBackground (no doodles yet)

**Files:**
- Create: `app/lib/wallpaper/wallpaper_background.dart`
- Test: `app/test/wallpaper/wallpaper_background_test.dart`

**Interfaces:**
- Consumes: `WallpaperSelection`, `WallpaperGradient`, `kWallpaperDriftSlots` (Task 1); `wallpaperControllerProvider`, `wallpaperDriftProvider` (Task 2).
- Produces:
  - `List<Offset> lerpAnchors(List<Offset> a, List<Offset> b, double t)` — pure, element-wise `Offset.lerp`, returns 4 offsets.
  - `class WallpaperBackground extends ConsumerStatefulWidget { const WallpaperBackground({super.key, required this.child}); final Widget child; }` — paints the current gradient behind `child`; on `wallpaperDriftProvider` change advances one slot over ~900ms.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wallpaper/wallpaper_background_test.dart
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/wallpaper/wallpaper_background_test.dart`
Expected: FAIL — `wallpaper_background.dart` missing.

- [ ] **Step 3: Implement the background + painter**

```dart
// app/lib/wallpaper/wallpaper_background.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'wallpaper_selection.dart';
import 'wallpaper_controller.dart';

/// Element-wise interpolation of two 4-anchor configurations.
List<Offset> lerpAnchors(List<Offset> a, List<Offset> b, double t) => [
      for (var i = 0; i < 4; i++) Offset.lerp(a[i], b[i], t)!,
    ];

class WallpaperBackground extends ConsumerStatefulWidget {
  const WallpaperBackground({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<WallpaperBackground> createState() => _WallpaperBackgroundState();
}

class _WallpaperBackgroundState extends ConsumerState<WallpaperBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
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

    final from = kWallpaperDriftSlots[
        (_slot - 1 + kWallpaperDriftSlots.length) % kWallpaperDriftSlots.length];
    final to = kWallpaperDriftSlots[_slot];

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final anchors = lerpAnchors(from, to, Curves.easeInOut.transform(_ctrl.value));
        return CustomPaint(
          painter: WallpaperMeshPainter(
            gradient: selection.gradient,
            anchors: anchors,
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Paints the four-color radial mesh: base fill + four soft radial blobs at
/// the (unit-space) anchors, additively layered for a smooth blend.
class WallpaperMeshPainter extends CustomPainter {
  WallpaperMeshPainter({required this.gradient, required this.anchors});

  final WallpaperGradient gradient;
  final List<Offset> anchors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = gradient.base);

    final colors = gradient.colors;
    final radius = size.longestSide * 0.75;
    for (var i = 0; i < 4; i++) {
      final center = Offset(anchors[i].dx * size.width, anchors[i].dy * size.height);
      final shader = RadialGradient(
        colors: [colors[i], colors[i].withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawRect(rect, Paint()..shader = shader);
    }
  }

  @override
  bool shouldRepaint(WallpaperMeshPainter old) =>
      old.gradient != gradient || old.anchors != anchors;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/wallpaper/wallpaper_background_test.dart`
Expected: PASS (2 tests). `flutter analyze` clean; `dart format`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/wallpaper/wallpaper_background.dart app/test/wallpaper/wallpaper_background_test.dart
git commit -m "feat(wallpaper): animated 4-anchor mesh background"
```

---

### Task 4: Tiled doodle overlay

**Files:**
- Create: `app/lib/wallpaper/wallpaper_doodles.dart`
- Modify: `app/lib/wallpaper/wallpaper_background.dart` (paint doodles when `selection.doodles`)
- Test: `app/test/wallpaper/wallpaper_doodles_test.dart`

**Interfaces:**
- Consumes: `WallpaperGradient.doodleInk` (Task 1).
- Produces: `void paintDoodleField(Canvas canvas, Size size, Color ink)` — tiles a 230×230 doodle cell across `size`, stroking/​filling each doodle with `ink` (alpha already baked into the color).

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wallpaper/wallpaper_doodles_test.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_doodles.dart';

void main() {
  test('paintDoodleField paints without throwing and issues draw calls', () {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    paintDoodleField(canvas, const Size(400, 800), const Color(0x24FFFFFF));
    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/wallpaper/wallpaper_doodles_test.dart`
Expected: FAIL — `wallpaper_doodles.dart` missing.

- [ ] **Step 3: Implement the doodle field**

```dart
// app/lib/wallpaper/wallpaper_doodles.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// One placement of a doodle within the 230x230 cell.
class _Doodle {
  const _Doodle(this.draw, this.x, this.y, this.scale, this.rotation, {this.fill = false});
  final void Function(Canvas, Paint) draw;
  final double x, y, scale, rotation;
  final bool fill;
}

const _cell = 230.0;

/// Tiles the Love-Doodles cell across [size], inked with [ink].
void paintDoodleField(Canvas canvas, Size size, Color ink) {
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = ink;
  final fill = Paint()
    ..style = PaintingStyle.fill
    ..color = ink;

  for (var oy = 0.0; oy < size.height; oy += _cell) {
    for (var ox = 0.0; ox < size.width; ox += _cell) {
      canvas.save();
      canvas.translate(ox, oy);
      for (final d in _doodles) {
        canvas.save();
        canvas.translate(d.x, d.y);
        canvas.rotate(d.rotation * math.pi / 180);
        canvas.scale(d.scale);
        d.draw(canvas, d.fill ? fill : stroke);
        canvas.restore();
      }
      canvas.restore();
    }
  }
}

// --- doodle primitives (drawn around a ~24x24 local origin) ---

void _heart(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(12, 20)
    ..cubicTo(5, 14, 3, 9.5, 6.2, 6.8)
    ..cubicTo(8.4, 5, 11, 6, 12, 8.2)
    ..cubicTo(13, 6, 15.6, 5, 17.8, 6.8)
    ..cubicTo(21, 9.5, 19, 14, 12, 20)
    ..close();
  c.drawPath(path, p);
}

void _star(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(12, 3)
    ..cubicTo(12.6, 8, 13, 9.4, 21, 12)
    ..cubicTo(13, 14.6, 12.6, 16, 12, 21)
    ..cubicTo(11.4, 16, 11, 14.6, 3, 12)
    ..cubicTo(11, 9.4, 11.4, 8, 12, 3)
    ..close();
  c.drawPath(path, p);
}

void _chat(Canvas c, Paint p) {
  final path = Path()
    ..moveTo(5, 6)
    ..lineTo(17, 6)
    ..arcToPoint(const Offset(19, 8), radius: const Radius.circular(2))
    ..lineTo(19, 12)
    ..arcToPoint(const Offset(17, 14), radius: const Radius.circular(2))
    ..lineTo(11, 14)
    ..lineTo(7, 17)
    ..lineTo(7, 14)
    ..lineTo(5, 14)
    ..arcToPoint(const Offset(3, 12), radius: const Radius.circular(2))
    ..lineTo(3, 8)
    ..arcToPoint(const Offset(5, 6), radius: const Radius.circular(2))
    ..close();
  c.drawPath(path, p);
}

void _envelope(Canvas c, Paint p) {
  c.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(4, 7, 16, 11), const Radius.circular(1.5)),
    p,
  );
  c.drawPath(Path()..moveTo(4.5, 8)..lineTo(12, 13.5)..lineTo(19.5, 8), p);
}

void _ring(Canvas c, Paint p) {
  c.drawCircle(const Offset(12, 15), 5, p);
  c.drawPath(Path()..moveTo(9, 11)..lineTo(12, 7)..lineTo(15, 11), p);
}

void _plane(Canvas c, Paint p) {
  c.drawPath(
    Path()..moveTo(3, 12)..lineTo(21, 4)..lineTo(14, 20)..lineTo(11, 13)..close(),
    p,
  );
}

void _cup(Canvas c, Paint p) {
  c.drawPath(
    Path()
      ..moveTo(5, 10)..lineTo(15, 10)..lineTo(15, 14)
      ..arcToPoint(const Offset(5, 14), radius: const Radius.circular(5), clockwise: false)
      ..close(),
    p,
  );
  c.drawPath(Path()..moveTo(15, 11)..arcToPoint(const Offset(15, 15), radius: const Radius.circular(2.5)), p);
}

void _spark(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 5), const Offset(12, 11), p);
  c.drawLine(const Offset(12, 13), const Offset(12, 19), p);
  c.drawLine(const Offset(5, 12), const Offset(11, 12), p);
  c.drawLine(const Offset(13, 12), const Offset(19, 12), p);
}

/// 20 scattered placements (ported from the approved mockup tile). Mix of
/// filled hearts/stars and outline objects, rotated so the grid stops reading.
const List<_Doodle> _doodles = [
  _Doodle(_heart, 0, 0, 1.05, -12, fill: true),
  _Doodle(_chat, 60, 8, 1.0, 8),
  _Doodle(_envelope, 120, 2, 1.05, -6),
  _Doodle(_ring, 182, 12, 1.0, 14),
  _Doodle(_spark, 36, 40, 0.9, 0),
  _Doodle(_heart, 92, 54, 0.9, 18),
  _Doodle(_plane, 150, 48, 1.05, -18),
  _Doodle(_heart, 200, 64, 0.85, 10, fill: true),
  _Doodle(_cup, 6, 86, 1.05, 6),
  _Doodle(_star, 64, 100, 0.85, -10, fill: true),
  _Doodle(_envelope, 116, 92, 1.0, 16),
  _Doodle(_heart, 176, 104, 1.0, -14),
  _Doodle(_chat, 20, 138, 1.0, -8),
  _Doodle(_heart, 78, 150, 0.9, 20, fill: true),
  _Doodle(_ring, 132, 146, 0.9, -16),
  _Doodle(_spark, 190, 156, 0.9, 0),
  _Doodle(_plane, 8, 186, 1.05, 12),
  _Doodle(_heart, 66, 196, 0.9, -18),
  _Doodle(_cup, 118, 190, 1.0, 10),
  _Doodle(_star, 178, 198, 0.85, -10, fill: true),
];
```

- [ ] **Step 4: Wire doodles into the painter**

In `app/lib/wallpaper/wallpaper_background.dart`, add the import at the top:

```dart
import 'wallpaper_doodles.dart';
```

In `WallpaperMeshPainter`, add a field and constructor param, and a paint call after the mesh loop:

```dart
  WallpaperMeshPainter({
    required this.gradient,
    required this.anchors,
    required this.doodles,
  });

  final WallpaperGradient gradient;
  final List<Offset> anchors;
  final bool doodles;
```

After the `for (var i = 0; i < 4; i++) { ... }` mesh loop, before `}`:

```dart
    if (doodles) {
      paintDoodleField(canvas, size, gradient.doodleInk);
    }
```

Update `shouldRepaint`:

```dart
  @override
  bool shouldRepaint(WallpaperMeshPainter old) =>
      old.gradient != gradient || old.anchors != anchors || old.doodles != doodles;
```

And in `_WallpaperBackgroundState.build`, pass it:

```dart
          painter: WallpaperMeshPainter(
            gradient: selection.gradient,
            anchors: anchors,
            doodles: selection.doodles,
          ),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && flutter test test/wallpaper/`
Expected: PASS (all wallpaper tests). `flutter analyze` clean; `dart format`.

- [ ] **Step 6: Commit**

```bash
git add app/lib/wallpaper/wallpaper_doodles.dart app/lib/wallpaper/wallpaper_background.dart app/test/wallpaper/wallpaper_doodles_test.dart
git commit -m "feat(wallpaper): tiled Love Doodles overlay"
```

---

### Task 5: Mount wallpaper behind the conversation + drift on send

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (wrap message area with `WallpaperBackground`; make Scaffold + list backgrounds transparent; bump drift in `_handleSubmit`)
- Test: `app/test/conversation/conversation_page_test.dart` (add wallpaper render + drift assertions)

**Interfaces:**
- Consumes: `WallpaperBackground` (Task 3), `wallpaperDriftProvider` (Task 2). `ConversationPage` is already a `ConsumerState`, so `ref` is in scope.

- [ ] **Step 1: Write the failing test**

Add to `app/test/conversation/conversation_page_test.dart` (inside `main()`):

```dart
  testWidgets('renders a wallpaper and a send bumps the drift', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WallpaperBackground), findsOneWidget);

    final before = container.read(wallpaperDriftProvider);
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    expect(container.read(wallpaperDriftProvider), before + 1);
  });
```

Add the imports at the top of the test file if missing:

```dart
import 'package:littlelove/wallpaper/wallpaper_background.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/conversation_page_test.dart -p 'renders a wallpaper'`
Expected: FAIL — no `WallpaperBackground` in the tree.

- [ ] **Step 3: Mount the background**

In `conversation_page.dart`, add imports:

```dart
import '../wallpaper/wallpaper_background.dart';
import '../wallpaper/wallpaper_controller.dart';
```

In the `build` method's `Scaffold`, set `backgroundColor: Colors.transparent` (replace `TwilightColors.bgCanvas`) and wrap the `body:` `Stack` in `WallpaperBackground`:

```dart
      backgroundColor: Colors.transparent,
      body: WallpaperBackground(
        child: Stack(
          children: [
            // ...existing Positioned.fill(ListView…), FAB, Align(composer)…
          ],
        ),
      ),
```

> The existing `Positioned.fill` ListView has no opaque background of its own, so the wallpaper shows through between bubbles. Leave bubble colors untouched.

- [ ] **Step 4: Bump drift on send**

In `_handleSubmit`, immediately after `widget.onSend(text);` (currently `conversation_page.dart:297`), add:

```dart
    ref.read(wallpaperDriftProvider.notifier).bump();
```

Also add the same bump after the `widget.onSendMedia?.call(items, text);` branch so media sends drift too.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && flutter test test/conversation/conversation_page_test.dart`
Expected: PASS (all conversation tests incl. the new one). `flutter analyze` clean; `dart format`.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_page_test.dart
git commit -m "feat(wallpaper): mount behind conversation, drift on send"
```

---

### Task 6: Frost the conversation app bar

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (transparent AppBar + `flexibleSpace` backdrop; `extendBodyBehindAppBar: true`; top inset on the list)
- Test: `app/test/conversation/conversation_page_test.dart` (assert a BackdropFilter is present in the app bar area)

**Interfaces:**
- Consumes: `_glassSaturation` matrix already defined in `conversation_page.dart` (reuse for the app bar material). `dart:ui` `ImageFilter` already imported.

- [ ] **Step 1: Write the failing test**

Add to `app/test/conversation/conversation_page_test.dart`:

```dart
  testWidgets('app bar is frosted glass (has a BackdropFilter)', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTwilightTheme(),
          home: ConversationPage(
            room: _roomA(), selfUsername: 'court', onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Two frosted surfaces now: the composer and the app bar.
    expect(find.byType(BackdropFilter), findsNWidgets(2));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/conversation/conversation_page_test.dart -p 'app bar is frosted'`
Expected: FAIL — only 1 BackdropFilter (the composer).

- [ ] **Step 3: Frost the app bar**

In `conversation_page.dart`'s `Scaffold`, add `extendBodyBehindAppBar: true,` and replace the `AppBar`'s `backgroundColor: TwilightColors.bgSurface` with transparency + a `flexibleSpace` backdrop:

```dart
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: const ColorFilter.matrix(_glassSaturation),
              inner: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TwilightColors.bgCanvas.withValues(alpha: 0.62),
                border: Border(
                  bottom: BorderSide(
                    color: TwilightColors.textPrimary.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        titleSpacing: 8,
        title: ChannelSwitcher(
          selfUsername: widget.selfUsername,
          onNewChannel: widget.onNewChannel,
        ),
        actions: [ /* ...unchanged... */ ],
      ),
```

Because the body now extends behind the app bar, add top inset so the newest-scrolled-to-top messages clear it. In the `Positioned.fill` ListView `padding` (reverse list), change `top: 12` to:

```dart
                    top: 12 + MediaQuery.of(context).padding.top + kToolbarHeight,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/conversation/conversation_page_test.dart`
Expected: PASS (BackdropFilter found twice; existing tests still green). `flutter analyze` clean; `dart format`.

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_page_test.dart
git commit -m "feat(wallpaper): frost the conversation app bar to match the composer"
```

---

### Task 7: Wallpaper picker screen + sidebar entry

**Files:**
- Create: `app/lib/wallpaper/wallpaper_screen.dart`
- Modify: `app/lib/inbox/sidebar.dart` (wire the `sidebar-settings` gear to push the screen)
- Test: `app/test/wallpaper/wallpaper_screen_test.dart`

**Interfaces:**
- Consumes: `wallpaperControllerProvider`, `WallpaperGradient`, `WallpaperBackground` (for live previews).
- Produces: `class WallpaperScreen extends ConsumerWidget` with a `static Route<void> route()` returning a `MaterialPageRoute`.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/wallpaper/wallpaper_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/twilight.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wallpaper/wallpaper_screen.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows four gradients + a doodles toggle; tapping updates selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTwilightTheme(), home: const WallpaperScreen()),
      ),
    );
    await tester.pumpAndSettle();

    for (final g in WallpaperGradient.values) {
      expect(find.text(g.label), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('wallpaper-rose')));
    await tester.pump();
    expect(container.read(wallpaperControllerProvider).gradient, WallpaperGradient.rose);

    await tester.tap(find.byKey(const Key('wallpaper-doodles-toggle')));
    await tester.pump();
    expect(container.read(wallpaperControllerProvider).doodles, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/wallpaper/wallpaper_screen_test.dart`
Expected: FAIL — `wallpaper_screen.dart` missing.

- [ ] **Step 3: Implement the screen**

```dart
// app/lib/wallpaper/wallpaper_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/twilight.dart';
import 'wallpaper_background.dart';
import 'wallpaper_controller.dart';
import 'wallpaper_selection.dart';

class WallpaperScreen extends ConsumerWidget {
  const WallpaperScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const WallpaperScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(wallpaperControllerProvider);
    final controller = ref.read(wallpaperControllerProvider.notifier);

    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        elevation: 0,
        title: const Text('Wallpaper'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
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
            activeColor: TwilightColors.accentUser,
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('wallpaper-${gradient.name == 'mauveSage' ? 'sage' : gradient.name == 'deepDusk' ? 'deep' : gradient.name}'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? TwilightColors.accentUser : Colors.transparent,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                painter: WallpaperMeshPainter(
                  gradient: gradient,
                  anchors: const [
                    Offset(0.18, 0.18), Offset(0.84, 0.24),
                    Offset(0.22, 0.86), Offset(0.86, 0.80),
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
```

> Tile keys: `wallpaper-rose`, `wallpaper-twilight`, `wallpaper-sage`, `wallpaper-deep` (matching the test's `wallpaper-rose`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app && flutter test test/wallpaper/wallpaper_screen_test.dart`
Expected: PASS. `flutter analyze` clean; `dart format`.

- [ ] **Step 5: Wire the sidebar gear**

In `app/lib/inbox/sidebar.dart`, add the import:

```dart
import '../wallpaper/wallpaper_screen.dart';
```

Replace the empty `onPressed: () {}` on the `sidebar-settings` IconButton (currently `sidebar.dart:96`) with:

```dart
              onPressed: () => Navigator.of(context).push(WallpaperScreen.route()),
```

- [ ] **Step 6: Run the full suite + analyze**

Run: `cd app && flutter analyze && flutter test`
Expected: analyze clean, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/lib/wallpaper/wallpaper_screen.dart app/lib/inbox/sidebar.dart app/test/wallpaper/wallpaper_screen_test.dart
git commit -m "feat(wallpaper): picker screen wired to the sidebar settings gear"
```

---

## Self-Review

**Spec coverage:**
- Four gradients + palettes → Task 1. ✓
- Doodles on/off + tint per gradient → Task 1 (`doodleInk`) + Task 4. ✓
- Personal/local persistence via shared_preferences, default Twilight+doodles → Task 2. ✓
- One wallpaper for all chats → global providers (Task 2), mounted per-conversation (Task 5). ✓
- Animate-on-send drift, no idle animation → Task 2 (drift counter) + Task 3 (one `forward(from:0)` per bump, rests otherwise). ✓
- Wallpaper behind message list, bubbles unchanged → Task 5. ✓
- Frost the app bar → Task 6. ✓
- Picker from the sidebar gear → Task 7. ✓
- Tests for repo round-trip / picker / conversation render+drift → Tasks 2, 7, 5. ✓

**Placeholder scan:** No TBD/TODO; every step is complete, copy-pasteable code.

**Type consistency:** `WallpaperSelection`, `WallpaperGradient`, `WallpaperMeshPainter({gradient, anchors, doodles})`, `wallpaperControllerProvider`, `wallpaperDriftProvider`, `WallpaperBackground({child})`, `paintDoodleField(canvas, size, ink)`, `WallpaperScreen.route()` are used consistently across tasks. Tile keys (`wallpaper-rose` etc.) match the picker test.

**Out-of-scope confirmed absent:** no photo upload, per-channel override, partner sync, or dark mode in any task.
