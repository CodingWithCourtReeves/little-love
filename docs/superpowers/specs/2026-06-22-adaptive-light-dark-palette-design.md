# Adaptive Light/Dark Palette — Design Spec

**Date:** 2026-06-22
**Status:** Approved design, pending plan
**Branch:** `telegram-composer`

## Goal

Make the selected wallpaper theme the **entire product**, not just the
conversation screen. Picking a dark wallpaper makes the whole app dark to
match; picking a light one makes it light. One warm-dusk identity, two
brightnesses, two people — so the app always feels like a single coherent,
intimate space rather than light chrome awkwardly floating over a dark
wallpaper.

This replaces the single compile-time `TwilightColors` palette with a
runtime palette delivered through `ThemeData`, driven by the wallpaper each
user already picks locally.

## Why (research-backed)

- **Couples apps want warm but muted color** — rose / coral / mauve read as
  closeness and affection; fiery saturated red reads hookup-dating; serene
  blue reads cold/transactional. Our existing "Twilight" world (aubergine
  canvas, dusty rose `#A04A6A`, sage) is already this. Sources:
  [COLOURlovers](https://www.colourlovers.com/blog/2018/11/13/choose-colors-scheme-relationship-dating-site/),
  [Octet romantic/intimate palettes](https://octet.design/colors/mood-based/romantic-intimate/).
- **Accent must not reuse the same hex across modes** — a saturated accent
  that works on light "vibrates" on dark and fails contrast. Rule: keep the
  hue, **lift lightness and drop ~20pts saturation** in dark, hold text/
  accents to **4.5:1**. Sources:
  [Smashing — inclusive dark mode](https://www.smashingmagazine.com/2025/04/inclusive-dark-mode-designing-accessible-dark-themes/),
  [Atmos](https://atmos.style/blog/dark-mode-ui-best-practices).
- **Two-partner hues** — the tokens already distinguish `accentUser` (rose,
  *you*) from `accentPartner` (`#9C7E94` mauve, *them*). That is the
  deliberately couples-app idea worth preserving in both brightnesses.

## Global Constraints

- iOS-only MVP. No new packages — Flutter `ThemeExtension` + existing
  `flutter_riverpod` only.
- Palette field names **mirror the current `TwilightColors` token names
  exactly**, so the call-site sweep is a near-mechanical
  `TwilightColors.x` → `context.palette.x`.
- Brand accent hue is constant across modes (identity); only its tone shifts.
- Every text/icon-on-surface pair targets WCAG AA **4.5:1**; large display
  text may use 3:1.
- The wallpaper mesh painter (`wallpaper_background.dart`,
  `wallpaper_selection.dart` gradient colors / `doodleInk`) is unchanged —
  this spec only adds chrome theming that *harmonizes* with it via brightness.

## Brightness mapping

`WallpaperGradient` gains a `Brightness get brightness`:

| Wallpaper        | base       | brightness |
|------------------|------------|------------|
| Rosé             | `#EFDCE2`  | light      |
| Mauve & Sage     | `#D8C9CF`  | light      |
| Twilight (default) | `#6B3D5C` | **dark**  |
| Deep Dusk        | `#2A1F2A`  | **dark**   |

**The default wallpaper is Twilight, which is dark — so the app boots into
the dark theme by default.** That is intentional and matches the default
chat background; it is also precisely the case that looked broken before.

## Token table — light (current) + dark (proposed)

Light values are today's `TwilightColors`, unchanged. Dark values are
derived from the Deep Dusk wallpaper world so the dark theme and the dark
wallpapers are literally the same night. Hexes are the design target; final
1–2 point tuning happens on-device.

| Token             | Light (current) | Dark (proposed) | Notes |
|-------------------|-----------------|-----------------|-------|
| `bgCanvas`        | `#F4EBEC`       | `#181019`       | scaffold / deepest |
| `bgSurface`       | `#EBDFE2`       | `#241A28`       | cards, sheets, app bar, glass base |
| `bgSurfaceAlt`    | `#E2D3D8`       | `#322438`       | pills, raised input |
| `textPrimary`     | `#2A1F2A`       | `#F4EBEC`       | ~13:1 on bgSurface |
| `textMuted`       | `#7C6C78`       | `#B7A6B1`       | ~7.9:1 on bgSurface (AA) |
| `accentUser`      | `#A04A6A`       | `#C98EA3`       | lifted+desaturated rose, ~6:1 |
| `accentUserSoft`  | `#C98EA3`       | `#E0B6C6`       | trailing double-heart |
| `accentPartner`   | `#9C7E94`       | `#B6A0B2`       | *them* hue, lifted |
| `accentSage`      | `#4F7A5E`       | `#8FB89A`       | secondary / section accent |
| `borderSoft`      | `#D9C7CD`       | `#3D2E42`       | warm low-contrast divider |
| `ruleStrong`      | `#4F7A5E`       | `#8FB89A`       | mirrors accentSage |
| `warningTone`     | `#B85C5C`       | `#E58A8A`       | lighter red for dark |
| `bubbleUserBg`    | `#E8C8D2`       | `#5E2C49`       | your bubble = deep rose (Deep Dusk anchor) |
| `bubbleUserText`  | `#3A1424`       | `#F6E5EC`       | ~13:1 on bubbleUserBg |
| `bubblePartnerBg` | `#FFFAFB`       | `#2E2233`       | their bubble = warm dark surface |

Partner bubble text in both modes uses `textPrimary` (light over dark
surface in dark mode). The conversation tail border (`borderSoft`) and the
frosted-glass tints in the composer/app bar read from these tokens, so the
chat chrome the earlier commits hardcoded now flips automatically.

### Contrast targets (verify in a unit test)

| Pair (dark)                         | Target | Approx |
|-------------------------------------|--------|--------|
| `textPrimary` on `bgSurface`        | 4.5:1  | ~13:1  |
| `textMuted` on `bgSurface`          | 4.5:1  | ~7.9:1 |
| `accentUser` on `bgSurface`         | 4.5:1  | ~6.2:1 |
| `bubbleUserText` on `bubbleUserBg`  | 4.5:1  | ~13:1  |
| `textPrimary` on `bubblePartnerBg`  | 4.5:1  | ~11:1  |

## Architecture

### 1. `AppPalette extends ThemeExtension<AppPalette>`

New `lib/theme/app_palette.dart`. Carries every token above as instance
fields (names identical to current `TwilightColors`). Provides:

- `static const AppPalette light` / `static const AppPalette dark`
- `Brightness get brightness`
- `copyWith(...)` and `lerp(...)` (component-wise `Color.lerp`) so theme
  changes cross-fade instead of snapping.

`TwilightColors` static class is **removed**; `twilight.dart` keeps only
`TwilightType` (see §3) and the theme builder (§2). Migration is the
call-site sweep (§4).

### 2. `buildAppTheme(AppPalette p)` → `ThemeData`

Replaces `buildTwilightTheme()`. Builds `ColorScheme` of the right
`brightness` (primary `accentUser`, secondary `accentSage`, surface
`bgSurface`, onSurface `textPrimary`, error `warningTone`),
`scaffoldBackgroundColor: bgCanvas`, and registers `extensions: [p]`.

Crucially it themes the **Material popups** so they adapt without
per-widget edits: `appBarTheme`, `dialogTheme`, `bottomSheetTheme`,
`popupMenuTheme`, `snackBarTheme`, `dividerTheme`, `textTheme`. This is how
the 4 popups (channel sheet, create-channel sheet, ⋯ menu, love-toast) come
along for free.

### 3. `TwilightType` becomes colorless

The five static text styles currently bake `textPrimary`/`textMuted`.
Strip `color` from them so they carry geometry only (size/weight/spacing);
color comes from `DefaultTextStyle`/`textTheme` (`onSurface`) per theme.
The handful of spots that specifically want muted pass
`context.palette.textMuted` explicitly. `buildAppTheme` wires `textTheme`
so default text is `textPrimary` in the active mode.

### 4. Delivery + provider wiring

- `BuildContext` extension: `AppPalette get palette =>
  Theme.of(this).extension<AppPalette>()!`.
- `paletteProvider` (in `lib/theme/`) watches `wallpaperControllerProvider`,
  maps `selection.gradient.brightness` → `AppPalette.light|dark`.
- The app root (where `MaterialApp` is built) watches `paletteProvider` and
  sets `theme: buildAppTheme(palette)`. Because the wallpaper controller
  already resolves synchronously to `defaults` (Twilight → dark) before its
  async `_load`, there is no light-flash on cold start; when `_load`
  finishes the theme lerps to the persisted choice.

### 5. Call-site sweep

Mechanical `TwilightColors.x` → `context.palette.x` across the 14 files
(`grep` list below), dropping `const` on the wrapping `TextStyle`/
`BoxDecoration`/`Icon` where a runtime color is now used. Where a widget
lacks a `BuildContext` in scope (rare — static helpers in
`conversation_page.dart` like `_markerWidget`/`_heart`), thread the palette
in as a parameter.

Files: `conversation/conversation_page.dart`, `inbox/channel_switcher.dart`,
`inbox/conversation_list_item.dart`, `screens/auth/auth_gate.dart`,
`screens/create_chat/create_channel_sheet.dart`,
`screens/create_chat/create_chat_invite_screen.dart`,
`screens/create_chat/create_chat_pick_screen.dart`,
`screens/inbox/inbox_shell.dart`, `screens/inbox/new_chat_screen.dart`,
`screens/pair/enter_code.dart`, `screens/pair/show_invite.dart`,
`theme/love_toast.dart`, `wallpaper/wallpaper_screen.dart`, plus the app
root that builds `MaterialApp`.

## Testing

- **Unit (`app_palette_test.dart`):** light & dark expose all fields;
  `brightness` correct; `lerp(light, dark, .5)` returns a blend (not a
  snap); gradient→brightness map is correct for all four wallpapers.
- **Contrast (`palette_contrast_test.dart`):** a WCAG relative-luminance
  helper asserts each pair in the Contrast-targets table is ≥ 4.5:1 in both
  palettes. Guards future token edits.
- **Widget (`theme_switch_test.dart`):** pump the app with a `deepDusk`
  wallpaper override → `Theme.of(context).brightness == Brightness.dark`
  and scaffold background is the dark `bgCanvas`; with `rose` →
  `Brightness.light`. Pump the conversation page in dark and assert a chrome
  icon resolves to the light token (e.g. the ⋯ menu / composer icons are no
  longer `#7C6C78`).
- **Existing suite:** tests that pump `buildTwilightTheme()` switch to
  `buildAppTheme(AppPalette.light)` (or `.dark` where a test asserts dark
  behavior). Update the conversation tests' theme construction accordingly.
  Full `flutter analyze` + `flutter test` must pass before finishing.

## Out of scope

- No change to the wallpaper mesh, gradients, doodles, or drift animation.
- No four-bespoke-palette option (decided: two brightnesses, constant brand
  hue).
- No user-facing "theme" toggle separate from wallpaper — brightness is a
  consequence of the wallpaper pick, by design.
- No server/sync work — palette is a local consequence of the local
  wallpaper choice.

## Open questions

None outstanding. Dark hexes are targets pending on-device tuning during
implementation; the contrast test is the guardrail that any tuning must
still satisfy.
