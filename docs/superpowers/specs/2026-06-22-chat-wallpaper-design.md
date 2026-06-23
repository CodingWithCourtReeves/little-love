# Personal chat wallpaper

**Date:** 2026-06-22
**Branch:** `telegram-composer` (continues the composer/glass work)
**Scope:** Conversation background + a wallpaper picker. Builds directly on the
frosted-glass composer already landed (the list scrolls under the glass, which
now has a wallpaper to blur).

## Decisions (locked)

- **Personal, not synced.** Each device stores its own choice; the partner is
  unaffected. No server/E2EE involvement.
- **One wallpaper for all chats** (global per-device preference, not per-channel).
- **A choice = one gradient + a doodles on/off toggle.**
  - Gradients (4): **Rosé**, **Twilight**, **Mauve & Sage**, **Deep Dusk** —
    each a 4-color set rendered as a soft radial mesh.
  - Pattern: **Love Doodles** overlay (hearts, letters, rings, planes, coffee,
    chat bubbles) or **None**. Tinted to suit the gradient (light tint over dark
    palettes, dark over light).
- **Default for new users: Twilight + Love Doodles on.**
- **Animate-on-send drift.** On each send the four color anchors spring to new
  positions, then rest. No idle animation (no battery cost when idle).
- **Frost the top app bar** to match the composer, so the wallpaper reads
  cohesively top and bottom.
- **Persistence:** add `shared_preferences` (no such dep today; identity uses
  secure storage, which is overkill for a non-secret UI pref).
- **Entry point:** the existing dead Settings gear in the sidebar
  (`sidebar-settings`) opens a new Wallpaper screen.

## Palette values (from approved mockups)

4-point radial mesh, corners → base:

- **Rosé:** #F7E3E8, #E8C8D2, #D9B8C6, #C98EA3 / base #EFDCE2
- **Twilight:** #5B3450, #A04A6A, #8A5A7A, #C98EA3 / base #6B3D5C
- **Mauve & Sage:** #C98EA3, #E2D3D8, #A9C2AC, #6E9B7A / base #D8C9CF
- **Deep Dusk:** #241A28, #5E2C49, #A04A6A, #3E2C3A / base #2A1F2A

## Components

- `WallpaperSelection` model — `{ gradient: WallpaperGradient enum, doodles: bool }`.
- `WallpaperRepository` — load/save via `shared_preferences`; default
  Twilight + doodles on. Exposed through a Riverpod provider with setters.
- `WallpaperGradient` — the four palettes + the anchor "slots" the drift cycles
  through.
- `WallpaperBackground` widget — `CustomPaint` drawing the 4-color radial mesh
  at four animatable anchors; an `AnimationController` springs between anchor
  configurations. Driven by a send-tick the conversation increments on send.
- Doodle overlay — the Love Doodles tile shipped as an SVG asset (reuse
  `flutter_svg`), tiled and tinted, layered above the gradient and below the
  message list.
- `WallpaperScreen` — grid of four gradient previews + a Love Doodles toggle,
  live-previewing; writes through the provider. Reached from `sidebar-settings`.

## Integration

- `ConversationPage`: render `WallpaperBackground` behind the message list
  (replacing the flat `bgCanvas`); increment the send-tick in the existing send
  path so the gradient drifts.
- App bar: transparent + `flexibleSpace` `BackdropFilter` (blur + ×1.3
  saturation + a 0.5px bottom hairline) matching the composer material;
  `extendBodyBehindAppBar: true` so messages scroll under it.

## Out of scope (YAGNI)

- Custom photo/upload wallpapers.
- Per-channel overrides.
- Syncing wallpaper to the partner.
- Dark-mode variants (app is light-only today).
- Additional pattern motifs beyond Love Doodles (Celestial/Botanical/Cozy were
  cut).

## Tests

- Repository round-trips selection; returns the Twilight+doodles default when
  unset.
- Picker updates the provider (and persists).
- `ConversationPage` renders the wallpaper; a send increments the drift tick.
