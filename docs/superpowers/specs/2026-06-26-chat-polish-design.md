# Chat polish: push-down composer, send animation, frosted top scrim

Date: 2026-06-26
Branch: `worktree-chat-polish`
Scope: `app/lib/conversation/conversation_page.dart` (plus a small set state field).

Three independent UI improvements to the conversation screen. Each is
self-contained and can be reviewed/tested separately.

## Background

The conversation screen (`conversation_page.dart`) renders messages in a
`reverse: true` `ListView.builder` inside a `Stack`. The composer floats at
the bottom of that Stack (`Align.bottomCenter`) as a frosted-glass bar; the
list reserves bottom padding equal to a post-frame-*measured* composer height
(`_composerHeight`, measured via `_composerKey` in `_measureComposer`). A flat
black->transparent gradient scrim sits at the very top so the OS clock and the
room title stay legible over the wallpaper.

`resizeToAvoidBottomInset` is `false`; the composer is lifted above the
keyboard manually with `Padding(bottom: keyboardInset)`, where `keyboardInset`
comes from `MediaQuery.viewInsets.bottom`.

## Item 1 — Growing input pushes the message list up

### Problem

When the input grows to a new line, the composer expands in place over the
list. The list only reserves matching space one frame *later* (the
`_measureComposer` post-frame measurement lags the growth), so a freshly typed
line briefly overlaps the newest message before the list catches up. Past a
few lines it visibly covers messages.

### Approach: Column layout (true push-down)

Restructure the Scaffold body from a Stack-with-floating-composer into a
Column so the list and composer share vertical space by layout constraint
rather than by measured padding:

```
WallpaperBackground(
  child: Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            Positioned.fill( GestureDetector( ListView reverse ) ),
            Positioned(top: 0, ... topScrim ),        // see Item 3
            Positioned(right: 16, bottom: 16, ... jumpToBottomFAB ),
          ],
        ),
      ),
      Padding(bottom: keyboardInset, child: composer),
    ],
  ),
)
```

When the composer grows a line, Flutter shrinks the `Expanded` list in the
**same layout pass** — messages push up instantly, never overlapped.

Consequences:

- **Delete the measurement machinery:** `_composerKey`, `_composerHeight`,
  `_measureComposer()`, the post-frame call that invokes it, and the
  `KeyedSubtree(key: _composerKey, ...)` wrapper. The list no longer needs a
  dynamic bottom pad keyed to composer height.
- **List bottom padding** becomes a small constant (e.g. `12`). Top padding
  (`12 + padding.top + kToolbarHeight`) is unchanged — the AppBar still floats
  over the list.
- **FAB re-anchors** from `bottom: _composerHeight + 16 + keyboardInset` to
  `bottom: 16` (it now lives inside the `Expanded`, whose bottom edge is the
  composer top).
- **Keyboard handling is unchanged:** `resizeToAvoidBottomInset` stays `false`;
  the composer keeps `Padding(bottom: keyboardInset)`. The `Expanded` list
  naturally sizes around composer + keyboard space.
- **Input cap:** lower the composer `TextField` `maxLines` from `8` to `6`
  (Flutter's conventional default), grow-then-cap-then-scroll-internally.

Accepted trade-off (chosen by the user over keeping the floating overlay):
messages no longer blur *through* the composer glass, because the list no
longer paints behind it. The composer keeps its own frosted appearance over
the wallpaper (its `BackdropFilter` now samples the wallpaper, not messages) —
no code change needed there, only the effect's backdrop changes.

### Testing

- Widget test: type text containing newlines into the composer field; assert
  the list's viewport/last-bubble position does not overlap the composer
  (or, more tractably, assert the composer height grows and the body remains a
  Column with an `Expanded` list — i.e. no `_composerHeight` padding path).
- Manual (two-sim harness): type 6+ lines; the list scrolls up smoothly with
  no bubble ever sliding under the composer; past 6 lines the field scrolls
  internally. Keyboard open/close still lifts/lowers the composer without
  churn.

## Item 2 — Scale/pop animation on newly-arrived messages

### Problem

New messages (both sent and received) appear instantly with no transition.

### Approach: one-shot scale + fade wrapper, gated by a seen-set

Add a `final Set<String> _animatedIds = {}` and a `bool _seededAnimics = false`
to the state. On the **first** build only, seed `_animatedIds` with every
currently-loaded message's stable key (then flip `_seededAnimics = true`) so
opening a room does not pop the entire history. Thereafter, in the bubble
`itemBuilder`, `Set.add` returns `true` only the first time a key is seen —
that is exactly a newly-arrived message — so wrap those in a one-shot
animation:

```
// once, before the list builds on the first frame:
if (!_seededAnimics) {
  for (final m in messages) _animatedIds.add(m.clientMsgId ?? m.id);
  _seededAnimics = true;
}

// in itemBuilder, per bubble:
final animKey = msg.clientMsgId ?? msg.id; // stable across reconcile
final firstAppearance = _animatedIds.add(animKey); // true => newly inserted
final child = _bubble(...);
return firstAppearance
  ? _PopIn(child: child, alignEnd: msg.from == me)
  : child;
```

The single seed-set is the only gate; there is no separate "is initial build"
check in the builder.

`_PopIn` is a small stateless wrapper around `TweenAnimationBuilder<double>`:

- duration ~220ms, curve `Curves.easeOutBack` (the "pop").
- `Transform.scale(scale: lerp(0.85 -> 1.0))` plus `Opacity(0 -> 1)` for a
  quick fade. Scale `alignment` is bottom-right for own messages
  (`msg.from == me`), bottom-left for incoming, so the bubble grows from its
  own corner rather than its center.
- Runs once (TweenAnimationBuilder fires on first build of the subtree and
  does not re-run while the end value is constant).

Applies to **both** sent and received new messages (user choice — "try both
and see"). Easy to later restrict to own-sent by gating on `msg.from == me`.

### Reconcile hazard (repo invariant)

Per CLAUDE.md ("Per-message status must survive the optimistic->server-id
reconcile"): when an optimistic message reconciles, its row id swaps from the
client id to the authoritative server id. Keying `_animatedIds` off
`clientMsgId ?? id` means:

- The optimistic send animates once (the desired send animation).
- After reconcile, the row still maps to the same `clientMsgId`, so it is
  already in `_animatedIds` and does **not** re-pop.
- A received message has no `clientMsgId`; it keys off `id`, which is stable on
  arrival, so it pops exactly once.

Verify `Msg` exposes `clientMsgId` (nullable) during implementation; if the
field name differs, use the actual optimistic-identity field. If no stable
client id is available for sent messages, fall back to keying off `id` and
accept that a reconcile *could* re-pop — then mitigate by also inserting the
new server id into `_animatedIds` at the reconcile site. (Prefer the
`clientMsgId` path; this is the fallback only.)

### Testing

- Widget test: pump the page with N seeded messages; assert none animate on
  first frame (seed-set covers them). Then add one message to the store; assert
  a `_PopIn`/`TweenAnimationBuilder` is present for that row and absent for the
  others. Pump past the duration; assert it settles at scale 1.0 / opacity 1.0.
- Widget test (reconcile): add an optimistic message (with `clientMsgId`), let
  it pop, then reconcile it to a server id; assert it does **not** pop a second
  time.
- Manual: send a message — it pops in from the bottom-right; receive one on the
  other sim — it pops from the bottom-left. Scrolling history does not pop old
  messages.

## Item 3 — Frosted, darker scrim under the top pills

### Problem

The top scrim is a flat `0x99000000 -> transparent` gradient with no blur, so
message text scrolling under the room-title pill and the OS clock blends with
them and stays sharp/legible-through, looking cluttered.

### Approach: stacked decreasing-sigma blur bands + darker gradient

Telegram's effect is a Gaussian blur that fades out downward plus a darker
gradient. The naive implementation (a single `BackdropFilter` masked by a
`ShaderMask`) hits a known Flutter compositing bug:
https://github.com/flutter/flutter/issues/175537 (BackdropFilter inside
ShaderMask does not composite correctly).

Instead, build the fade out of a few stacked thin horizontal bands, each its
own `ClipRect` + `BackdropFilter` with **decreasing** blur sigma top-to-bottom.
This yields a smooth blur falloff with no hard cut line and avoids the shader
bug:

```
Positioned(top:0, left:0, right:0, height: bandHeight,
  child: IgnorePointer(
    child: Stack(children: [
      // e.g. 3-4 sub-bands, top strongest:
      _blurBand(top: 0,         h: bandHeight*0.45, sigma: 12),
      _blurBand(top: h*0.45,    h: bandHeight*0.30, sigma: 6),
      _blurBand(top: h*0.75,    h: bandHeight*0.25, sigma: 2),
      // darker gradient on top of the blur:
      DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: topCenter, end: bottomCenter,
        colors: [Color(0xCC000000), Color(0x00000000)]))),
    ]),
  ),
)
```

Notes:

- Reuse the composer's `_glassSaturation` color matrix composed with the blur
  (same material as the existing frosted composer) so the glass reads
  consistently across the screen. `ImageFilter.compose(outer: ColorFilter.
  matrix(_glassSaturation), inner: ImageFilter.blur(...))`.
- `bandHeight` = `padding.top + kToolbarHeight + 12` (unchanged), possibly a
  touch taller to give the fade more room; tune visually.
- Strengthen the gradient from `0x99000000` to ~`0xCC000000` at the top.
- Exact sub-band count / sigmas / split ratios are tunable during
  implementation; 3–4 bands is enough for a smooth falloff. Keep the band area
  small (it is) since `BackdropFilter` is expensive.
- Lives inside the `Expanded`'s Stack (Item 1), drawn after the ListView so
  messages scroll under it.

### Testing

- Widget test: assert the top overlay contains `BackdropFilter`(s) and a
  gradient with the strengthened top alpha; assert it is wrapped in
  `IgnorePointer` (taps pass through to the list).
- Manual: scroll messages up under the top pills — text frosts and darkens as
  it passes under, the pills stop blending, and there is no hard horizontal
  line at the bottom of the blur band.

## Out of scope

- No change to message send/receive logic, the MessageStore, or the wire
  protocol.
- No new packages (no `gradient_blur`); implement with framework primitives.
- AnimatedList conversion is explicitly rejected (it would fight the existing
  keyed-subtree reconcile in the ListView).

## Verification (per repo rules)

Before pushing: `dart format`, full `flutter analyze`, `flutter test`, and a
build/run on the two-simulator harness (`scripts/sim-couple.sh`) to eyeball all
three effects on both sides. A green `flutter test`/`analyze` does not prove an
iOS build works — confirm on the sim/device.
