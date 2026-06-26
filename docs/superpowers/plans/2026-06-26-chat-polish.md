# Chat Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three conversation-screen polish items: the composer pushes the message list up as it grows (no overlap), new messages pop in with a scale/fade, and the top scrim frosts + darkens the messages scrolling under the pills.

**Architecture:** All changes live in `app/lib/conversation/conversation_page.dart`. Item 1 restructures the Scaffold body from a floating-composer `Stack` into a `Column` of `Expanded(Stack[list, scrim, fab])` + composer, deleting the post-frame composer-height measurement. Item 2 wraps newly-arrived bubbles in a one-shot `TweenAnimationBuilder`, gated by a seed-set so history never re-animates. Item 3 replaces the flat top gradient with stacked decreasing-sigma `BackdropFilter` bands plus a darker gradient.

**Tech Stack:** Flutter, Riverpod, Dart. Framework primitives only — no new packages.

## Global Constraints

- Single file under change: `app/lib/conversation/conversation_page.dart` (tests in `app/test/conversation/`).
- No new dependencies (no `gradient_blur`); use framework primitives.
- No changes to MessageStore, the wire protocol, or send/receive logic.
- No em dashes in any user-facing copy (none added here anyway).
- Reconcile invariant (CLAUDE.md): per-message UI state must survive the optimistic→server-id swap; key the animation seed-set off `clientMsgId ?? id`.
- `Msg` fields available: `id` (String), `from` (String), `to` (String), `body` (String), `ts` (DateTime), `clientMsgId` (String?).
- Verification before push (per repo rules): `dart format`, full `flutter analyze`, `flutter test`, then the two-sim harness for a visual pass. Green analyze/test does NOT prove the iOS build — confirm on sim.

---

### Task 1: Column push-down layout (item 1)

Restructure the body so the list shrinks in-layout as the composer grows, and remove the now-dead measurement machinery.

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`
  - Body `Stack`→`Column`: lines ~1103-1216 (`WallpaperBackground(child: Stack(...))`).
  - Delete measurement state: `_composerKey`/`_composerHeight` (lines ~362-363), `_measureComposer()` (lines ~376-383), the post-frame call (line ~933).
  - Composer `maxLines: 8`→`6` (line ~2001).
- Test: `app/test/conversation/conversation_page_layout_test.dart` (new).

**Interfaces:**
- Consumes: existing `_composer()`, `_scrollController`, `items`, `keyboardInset`, `_atBottom`, `_animateToBottom`, `context.palette`.
- Produces: body is `WallpaperBackground > Column[ Expanded(Stack[list, topScrim, fab]), Padding(bottom: keyboardInset, composer) ]`. No `_composerHeight` symbol remains. The top-scrim `Positioned` and FAB `Positioned` move inside the Expanded's Stack; FAB anchors at `bottom: 16`.

- [ ] **Step 1: Write the failing test**

Create `app/test/conversation/conversation_page_layout_test.dart`. Reuse the harness shape from `conversation_page_test.dart` (copy the `_roomA()`, `_account`, `_readStateStore` helpers and the `accountProvider`/`httpClientProvider`/`readStateStoreProvider` overrides verbatim — the engineer may read tasks out of order, so the full helper block is reproduced here):

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/message.dart';

Room _roomA() => Room(
  roomId: 'roomA',
  name: 'Kaitlyn',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'CCC', x25519PubBase64: 'DDD'),
  ],
  createdAt: DateTime.utc(2026, 6, 9),
);

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 9),
);

final _readStateStore = ReadStateStore(
  homeDirectory: Directory.systemTemp.createTempSync('conv_layout_rs'),
);

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: ConversationPage(
          room: _roomA(),
          selfUsername: 'court',
          onSend: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('body is a Column with an Expanded message region above the composer', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(id: '1', from: 'kaitlyn', to: 'court', body: 'hi', ts: DateTime.utc(2026, 6, 9, 17, 3)),
    ]);

    await _pump(tester, container);

    // The composer field and the message list both render...
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);

    // ...and the message list sits in an Expanded inside a Column (push-down
    // layout), not in a full-bleed Stack behind a floating composer.
    final listView = find.byType(ListView);
    expect(listView, findsOneWidget);
    expect(
      find.ancestor(of: listView, matching: find.byType(Expanded)),
      findsOneWidget,
    );
  });

  testWidgets('composer field caps at 6 lines', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    await _pump(tester, container);

    final field = tester.widget<TextField>(find.byKey(const Key('composer')));
    expect(field.maxLines, 6);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/conversation/conversation_page_layout_test.dart`
Expected: FAIL — the `Expanded` ancestor is absent (list is in a `Positioned.fill` Stack child) and `maxLines` is still 8.

- [ ] **Step 3: Restructure the body to a Column**

In `build()`, replace the body `WallpaperBackground(child: Stack(children: [ Positioned.fill(list), Positioned(scrim), Positioned(fab), Align(composer) ]))` (lines ~1103-1216) with a Column. Keep the list's `GestureDetector` + `ListView.builder` exactly as-is **except** change its `padding` `bottom` from `_composerHeight + 12 + keyboardInset` to a constant `12`. Move the top-scrim `Positioned` (see Task 3 for its new body; for now keep the existing flat-gradient `Positioned` unchanged) and the FAB `Positioned` inside the Expanded's Stack; change the FAB's `bottom:` from `_composerHeight + 16 + keyboardInset` to `16`. Put the composer in the Column below, retaining `Padding(bottom: keyboardInset)` but dropping the `KeyedSubtree(key: _composerKey, ...)` wrapper:

```dart
body: WallpaperBackground(
  child: Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 12 + MediaQuery.of(context).padding.top + kToolbarHeight,
                    bottom: 12,
                  ),
                  itemCount: items.length,
                  findChildIndexCallback: (key) {
                    final value = (key as ValueKey<String>).value;
                    final idx = items.indexWhere((it) => _rowKey(it) == value);
                    return idx < 0 ? null : idx;
                  },
                  itemBuilder: (_, i) {
                    final item = items[i];
                    final child = switch (item) {
                      _BubbleItem(:final msg) => _bubble(
                        msg, me, status.inBubble[msg.id], status.failedRun[msg.id],
                      ),
                      _DayItem(:final day) => _daySeparator(day),
                      _GapItem(:final time) => _gapHeader(time),
                    };
                    return KeyedSubtree(key: ValueKey(_rowKey(item)), child: child);
                  },
                ),
              ),
            ),
            // top scrim — unchanged flat gradient for now; Task 3 replaces its body.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x99000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: _atBottom ? 0 : 1,
                child: IgnorePointer(
                  ignoring: _atBottom,
                  child: FloatingActionButton.small(
                    key: const Key('jump-to-bottom'),
                    backgroundColor: context.palette.bgSurface,
                    foregroundColor: context.palette.accentUser,
                    elevation: 4,
                    onPressed: _animateToBottom,
                    tooltip: 'Jump to latest',
                    child: const Icon(Icons.arrow_downward),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: _composer(),
      ),
    ],
  ),
),
```

- [ ] **Step 4: Delete the dead measurement machinery**

- Remove the post-frame measure call (line ~931-933):
  ```dart
  SchedulerBinding.instance.addPostFrameCallback((_) => _measureComposer());
  ```
  Keep the `keyboardInset` line that follows it.
- Remove the field declarations (lines ~358-363) for `_composerKey` and `_composerHeight`, and their doc comment.
- Remove the `_measureComposer()` method (lines ~376-383) and its doc comment.
- If `SchedulerBinding` / `package:flutter/scheduler.dart` is now unused, remove the import (let `flutter analyze` in Step 6 confirm; only remove if flagged unused).

- [ ] **Step 5: Lower the composer line cap**

In `_composer()` change `maxLines: 8,` (line ~2001) to `maxLines: 6,`.

- [ ] **Step 6: Run analyze + the test to verify pass**

Run: `cd app && flutter analyze && flutter test test/conversation/conversation_page_layout_test.dart`
Expected: analyze clean (no "unused `_composerHeight`" / "undefined name" errors), test PASS.

Also run the existing suite to catch regressions in layout-dependent tests:
Run: `cd app && flutter test test/conversation/`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_page_layout_test.dart
git commit -m "feat(chat): push message list up as composer grows (Column layout)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Scale/pop animation on new messages (item 2)

Wrap freshly-arrived bubbles (sent and received) in a one-shot scale + fade, seeded so history never animates and reconcile never re-pops.

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`
  - Add state fields near the other animation/seen-set state (e.g. by `_animatedIds`/`_prevMessageCount`, line ~388).
  - Seed logic in `build()` before `items` is consumed (after `messages` is read, line ~889).
  - Wrap the `_BubbleItem` branch of `itemBuilder` (inside the Task-1 Column body).
  - Add a private `_PopIn` widget (top-level, near other small widgets at end of file).
- Test: `app/test/conversation/conversation_page_anim_test.dart` (new).

**Interfaces:**
- Consumes: `messages` (`List<Msg>`), `me` (String), `_bubble(...)`.
- Produces:
  - State: `final Set<String> _animatedIds = {}; bool _seededAnimics = false;`
  - Widget: `class _PopIn extends StatelessWidget { const _PopIn({required this.child, required this.alignEnd}); final Widget child; final bool alignEnd; }` — renders a 220ms `TweenAnimationBuilder<double>` from 0→1, `Curves.easeOutBack`, scaling 0.85→1.0 and fading 0→1, scale `alignment` = bottomRight if `alignEnd` else bottomLeft.

- [ ] **Step 1: Write the failing test**

Create `app/test/conversation/conversation_page_anim_test.dart`. Reuse the same helper block as Task 1 (`_roomA`, `_account`, `_readStateStore`, `_pump`, and the three provider overrides — reproduce them verbatim; temp-dir prefix `conv_anim_rs`). Then:

```dart
void main() {
  testWidgets('seeded history does not pop on open', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(id: '1', from: 'kaitlyn', to: 'court', body: 'old', ts: DateTime.utc(2026, 6, 9, 17, 1)),
    ]);
    await _pump(tester, container);

    // No pop wrapper for pre-existing history.
    expect(find.byType(_PopInProbe), findsNothing); // see note below
  });
}
```

Note: `_PopIn` is private to the library, so a test cannot import it by name. Instead, assert on observable animation state. Replace the body above with this approach that needs no access to the private type — drive a frame mid-animation and assert a `Transform` (scale) is present only for the new message:

```dart
void main() {
  testWidgets('a newly added message animates in; existing ones do not', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.setAll([
      Msg(id: '1', from: 'kaitlyn', to: 'court', body: 'old', ts: DateTime.utc(2026, 6, 9, 17, 1)),
    ]);
    await _pump(tester, container);

    // Settled history: the bubble text renders at full opacity (no in-flight fade).
    final oldOpacityFinder = find.ancestor(
      of: find.text('old'),
      matching: find.byType(Opacity),
    );
    // No animating Opacity wrapping history (seeded => skipped).
    expect(oldOpacityFinder, findsNothing);

    // Add a new message and pump a single short frame so the animation is mid-flight.
    store.add(Msg(id: '2', from: 'court', to: 'kaitlyn', body: 'new', ts: DateTime.utc(2026, 6, 9, 17, 2)));
    await tester.pump(); // build with the pop wrapper
    await tester.pump(const Duration(milliseconds: 60)); // mid-animation

    final newOpacity = find.ancestor(
      of: find.text('new'),
      matching: find.byType(Opacity),
    );
    expect(newOpacity, findsWidgets); // the pop wrapper is present for the new bubble
    final opacity = tester.widgetList<Opacity>(newOpacity).first;
    expect(opacity.opacity, lessThan(1.0)); // still fading in

    await tester.pumpAndSettle();
    // After settle the wrapper holds at full opacity.
    final settled = tester.widgetList<Opacity>(
      find.ancestor(of: find.text('new'), matching: find.byType(Opacity)),
    );
    expect(settled.every((o) => o.opacity == 1.0), isTrue);
  });
}
```

(If `_bubble` already nests an `Opacity` for unrelated reasons, scope the finder to the `_PopIn`'s `Transform` instead — pick whichever wrapper `_PopIn` introduces that is not otherwise present around `old`. The intent: the new bubble shows an in-flight fade/scale; the old one does not.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/conversation/conversation_page_anim_test.dart`
Expected: FAIL — no pop wrapper exists yet, so the new bubble has no in-flight `Opacity < 1.0`.

- [ ] **Step 3: Add the `_PopIn` widget**

Add near the other small private widgets at the end of the file:

```dart
/// One-shot "pop" for a newly-arrived message: a quick scale-up from the
/// bubble's own bottom corner plus a fade. Runs once on first build of the
/// subtree (TweenAnimationBuilder fires when the end value first appears and
/// does not re-run while it stays constant).
class _PopIn extends StatelessWidget {
  const _PopIn({required this.child, required this.alignEnd});

  final Widget child;
  /// Own messages grow from the bottom-right; partner messages bottom-left.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, t, child) {
        final scale = 0.85 + 0.15 * t;
        // easeOutBack overshoots past 1.0; clamp opacity so it never exceeds 1.
        final opacity = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            alignment: alignEnd ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
```

- [ ] **Step 4: Add the seed-set state and seeding logic**

Add fields near `_prevMessageCount` (line ~388):

```dart
/// Message keys already on screen / already popped, so opening a room does not
/// animate the whole history and a reconcile does not re-pop. Keyed off
/// `clientMsgId ?? id` so the optimistic→server-id swap maps to the same entry.
final Set<String> _animatedIds = {};
bool _seededAnimics = false;
```

In `build()`, right after `final messages = ref.watch(messageStoreProvider(widget.roomId));` (line ~889), seed once:

```dart
if (!_seededAnimics) {
  for (final m in messages) {
    _animatedIds.add(m.clientMsgId ?? m.id);
  }
  _seededAnimics = true;
}
```

- [ ] **Step 5: Wrap new bubbles in the itemBuilder**

In the `_BubbleItem` case of the Task-1 `itemBuilder`, compute the pop wrapper. Replace:

```dart
_BubbleItem(:final msg) => _bubble(
  msg, me, status.inBubble[msg.id], status.failedRun[msg.id],
),
```

with a block that wraps first-appearance bubbles:

```dart
_BubbleItem(:final msg) => () {
  final bubble = _bubble(
    msg, me, status.inBubble[msg.id], status.failedRun[msg.id],
  );
  final animKey = msg.clientMsgId ?? msg.id;
  // Set.add returns true only the first time we see this key — i.e. a
  // message that arrived after the initial seed: pop it in.
  final firstAppearance = _animatedIds.add(animKey);
  return firstAppearance
      ? _PopIn(child: bubble, alignEnd: msg.from == me)
      : bubble;
}(),
```

(The switch arm becomes an immediately-invoked closure so the local `bubble`/`animKey` stay scoped. If the surrounding `switch` is an expression that disallows statements, hoist this into a small `Widget _bubbleRow(Msg msg, String me, _StatusModel status)` helper method and call it from the arm; keep the logic identical.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd app && flutter test test/conversation/conversation_page_anim_test.dart`
Expected: PASS — new bubble fades/scales in, history does not.

- [ ] **Step 7: Reconcile-safety test**

Append to the same test file:

```dart
  testWidgets('an optimistic send does not re-pop after reconcile', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.setAll(const []);
    await _pump(tester, container);

    // Optimistic send: a client-id-bearing message.
    store.add(Msg(
      id: 'optimistic-1',
      clientMsgId: 'cmid-1',
      from: 'court',
      to: 'kaitlyn',
      body: 'sent',
      ts: DateTime.utc(2026, 6, 9, 17, 5),
    ));
    await tester.pumpAndSettle(); // first pop completes

    // Reconcile: same clientMsgId, authoritative server id.
    store.reconcile(
      Msg(
        id: 'server-1',
        clientMsgId: 'cmid-1',
        from: 'court',
        to: 'kaitlyn',
        body: 'sent',
        ts: DateTime.utc(2026, 6, 9, 17, 5),
      ),
    );
    await tester.pump(); // rebuild post-reconcile
    await tester.pump(const Duration(milliseconds: 60));

    // No in-flight fade: the row keyed off cmid-1 was already animated.
    final reFade = find.ancestor(of: find.text('sent'), matching: find.byType(Opacity));
    final anyFading = tester.widgetList<Opacity>(reFade).any((o) => o.opacity < 1.0);
    expect(anyFading, isFalse);
  });
```

Before running, confirm the `MessageStore.reconcile` signature (open `app/lib/conversation/message_store.dart`); adjust the call to match its actual parameters (it may take `(clientMsgId, serverMsg)` or a single `Msg`). The assertion — "no re-pop after reconcile" — stays the same regardless of the exact call shape.

Run: `cd app && flutter test test/conversation/conversation_page_anim_test.dart`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_page_anim_test.dart
git commit -m "feat(chat): pop new messages in with a scale + fade

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Frosted, darker top scrim (item 3)

Replace the flat top gradient with stacked decreasing-sigma blur bands plus a darker gradient, so messages frost and darken as they pass under the pills.

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`
  - The top-scrim `Positioned` inside the Expanded's Stack (added in Task 1).
  - Add a `_topScrim()` builder method + a `_blurBand(...)` helper near `_composer()`.
- Test: `app/test/conversation/conversation_page_scrim_test.dart` (new).

**Interfaces:**
- Consumes: `MediaQuery.padding.top`, `kToolbarHeight`, `_glassSaturation` (existing static matrix, line ~369).
- Produces: `Widget _topScrim(BuildContext context)` returning the `Positioned` top band: an `IgnorePointer` over a `Stack` of 3 `BackdropFilter` sub-bands (sigma 12 → 6 → 2, top to bottom) topped by a `DecoratedBox` gradient `0xCC000000 → 0x00000000`.

- [ ] **Step 1: Write the failing test**

Create `app/test/conversation/conversation_page_scrim_test.dart`. Reuse the Task-1 helper block (temp prefix `conv_scrim_rs`). Then:

```dart
void main() {
  testWidgets('top scrim frosts (BackdropFilter) and is pointer-transparent', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(id: '1', from: 'kaitlyn', to: 'court', body: 'hi', ts: DateTime.utc(2026, 6, 9, 17, 3)),
    ]);
    await _pump(tester, container);

    // A top scrim keyed for the test exists, is an IgnorePointer, and frosts
    // (contains at least one BackdropFilter) — i.e. not the old flat gradient.
    final scrim = find.byKey(const Key('top-scrim'));
    expect(scrim, findsOneWidget);
    expect(
      find.descendant(of: scrim, matching: find.byType(BackdropFilter)),
      findsWidgets,
    );
    expect(
      find.ancestor(of: find.byType(BackdropFilter).first, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/conversation/conversation_page_scrim_test.dart`
Expected: FAIL — no `Key('top-scrim')` and no `BackdropFilter` in the top band (still the flat gradient from Task 1).

- [ ] **Step 3: Add the `_topScrim` + `_blurBand` builders**

Add near `_composer()`:

```dart
/// Frosted, darkened band behind the status bar + app-bar pills. Messages
/// scroll under it and blur/darken so the OS clock and the room title stay
/// legible, Telegram-style. Built from stacked blur sub-bands with decreasing
/// sigma (strong at the very top, fading down) rather than a single
/// ShaderMask-over-BackdropFilter, which mis-composites
/// (flutter/flutter#175537). Drawn over the message list; pointer-through.
Widget _topScrim(BuildContext context) {
  final h = MediaQuery.of(context).padding.top + kToolbarHeight + 12;
  return Positioned(
    key: const Key('top-scrim'),
    top: 0,
    left: 0,
    right: 0,
    height: h,
    child: IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _blurBand(top: 0, height: h * 0.45, sigma: 12),
          _blurBand(top: h * 0.45, height: h * 0.30, sigma: 6),
          _blurBand(top: h * 0.75, height: h * 0.25, sigma: 2),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Color(0x00000000)],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// One horizontal blur slice of the top scrim. Reuses the composer's
/// saturation matrix so the glass material matches across the screen.
Widget _blurBand({
  required double top,
  required double height,
  required double sigma,
}) {
  return Positioned(
    top: top,
    left: 0,
    right: 0,
    height: height,
    child: ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: const ColorFilter.matrix(_glassSaturation),
          inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        ),
        child: const SizedBox.expand(),
      ),
    ),
  );
}
```

- [ ] **Step 4: Swap the flat gradient for `_topScrim`**

In the Expanded's Stack (from Task 1), replace the top-scrim `Positioned(... flat gradient ...)` child with `_topScrim(context)`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd app && flutter test test/conversation/conversation_page_scrim_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_page_scrim_test.dart
git commit -m "feat(chat): frost + darken the top scrim under the pills

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Full verification + visual pass

**Files:** none (verification only).

- [ ] **Step 1: Format + analyze + full test suite**

Run:
```bash
cd app && dart format lib/conversation/conversation_page.dart test/conversation/ && flutter analyze && flutter test
```
Expected: format reports the files (or no change), analyze clean, all tests PASS. Fix any fallout (most likely: an existing test that asserted the old `Stack`/`_composerHeight` layout, or an unused import). Re-run until green.

- [ ] **Step 2: Visual pass on the two-sim harness**

Per CLAUDE.md, a green `flutter test`/`analyze` does NOT prove the iOS build or the visuals. Bring up both sims and eyeball all three effects:

```bash
./scripts/sim-couple.sh
```
Then attach `flutter run` per sim for hot reload. Confirm:
1. Typing 6+ lines pushes the message list up smoothly with no bubble ever sliding under the composer; past 6 lines the field scrolls internally; keyboard open/close still lifts/lowers the composer cleanly.
2. Sending a message pops it in from the bottom-right; a received message pops from the bottom-left; scrolling history does not pop old messages.
3. Scrolling messages up under the top pills frosts + darkens them with no hard line at the band's bottom edge; the clock and room title stay legible.

- [ ] **Step 3: Commit any visual tuning**

If sigma values, band ratios, gradient alpha, scale/duration, or padding need tuning after the visual pass, adjust and commit:
```bash
git add app/lib/conversation/conversation_page.dart
git commit -m "fix(chat): tune chat-polish visuals after on-sim pass

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes

- **Spec coverage:** Item 1 → Task 1; Item 2 → Task 2; Item 3 → Task 3; spec's verification section → Task 4. Reconcile hazard → Task 2 Step 7. `maxLines` cap → Task 1 Step 5.
- **Type consistency:** `_PopIn({child, alignEnd})`, `_animatedIds`/`_seededAnimics`, `_topScrim(context)`/`_blurBand({top, height, sigma})`, `Msg.clientMsgId` — all used consistently across tasks.
- **Known unknowns flagged inline:** `MessageStore.reconcile` signature (Task 2 Step 7) and whether `_bubble` already nests an `Opacity` (Task 2 Step 1) are called out with concrete fallback instructions rather than left vague.
