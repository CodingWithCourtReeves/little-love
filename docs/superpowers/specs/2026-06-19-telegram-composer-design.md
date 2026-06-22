# Telegram-style composer (chat bar) redesign

**Date:** 2026-06-19
**Branch:** `telegram-composer`
**Scope:** `app/lib/conversation/conversation_page.dart` — the message composer only.

## Problem

The current composer reads as three detached pieces: a `+` button floating
outside on the left, a rounded text field in the middle, and a send circle
that pops in/out outside on the right. Telegram's bar feels more polished
because it reads as **one cohesive pill** with the attach action tucked
*inside* it, and a single trailing button that **morphs** between an
idle (mic) and active (send) state instead of a detached circle appearing
and disappearing.

## Decision (Option B)

One seamless pill + a morphing trailing button.

- **The pill:** a rounded (`radius 22`) container filled with
  `TwilightColors.bgSurfaceAlt`, holding the attach button inside-left and
  the `TextField` (transparent, borderless) expanding to fill. Bottom-aligned
  contents so the attach glyph stays pinned to the last line as the field
  grows. Built as an explicit `Container` + `Row` (not `prefixIcon`) so the
  attach icon bottom-aligns cleanly on multiline instead of vertically
  centering.
- **Trailing button:** lives *outside* the pill on the right and is
  **always present**. An `AnimatedSwitcher` cross-fades between:
  - empty → **mic** (`Icons.mic`, `textMuted`, no fill) — affordance only,
    no voice capture yet; tap shows a brief "Voice messages coming soon"
    SnackBar so it isn't a dead control.
  - has content (text or staged media) → **send** (filled `accentUser`
    circle, `Icons.arrow_upward`, white) — unchanged behavior.
- **Emoji button:** dropped (the iOS keyboard already has an emoji key).

## Constraints honored

- Keys preserved: `composer`, `composer-send`, `composer-attach`,
  `staging-tray`. New: `composer-mic`.
- The send button must stay **hit-testable after a single `pump()`** (the
  existing test enters text, pumps once, taps send). The morph therefore
  uses a **fade** transition (full layout size, hittable at any opacity),
  never scale-from-zero.
- Cmd/Ctrl+Enter send shortcut, multiline grow (1–8 lines), and the staged
  media tray are unchanged.

## Out of scope (YAGNI)

- Actual voice-note recording.
- An attach action sheet with multiple sources (Option C) — only one
  `onPickMedia` source exists today.
- Reply/edit preview banner (doesn't exist yet; separate work).

## Tests

- Mic button shown (and send absent) when the composer is empty.
- Send button shown (and mic absent) once text is entered; tapping it fires
  `onSend` — extends the existing single-pump test.
- Attach button still present and still calls the pick flow.
