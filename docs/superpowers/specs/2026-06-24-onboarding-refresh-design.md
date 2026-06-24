# Onboarding refresh — design

Date: 2026-06-24
Branch: `worktree-onboarding-refresh`

## Problem

A brand-new user's first impression of Little Love is flat. The welcome
("choice") screen is plain typography on a flat background, and the
12-word recovery-phrase step is the worst offender: a bare numbered grid,
terse warning copy, and **no copy button**, so the user has to hand-copy or
screenshot twelve words. We get one shot at a first impression and the
current flow wastes it.

## Goal

Make the new-user flow feel crafted and warm, on-brand with the existing
"twilight / dusk" palette, and fix the concrete usability gap on the
recovery-phrase step (add a copy button + real visual treatment). Bring all
four onboarding screens up to one consistent quality bar, matching the
already-decent pairing screen.

## Scope

In scope (the four new-user screens, both light + dark palettes):

1. **Welcome / choice screen** — `app/lib/screens/auth/auth_gate.dart`
   (`_ChoiceScreen`).
2. **Username step** — `app/lib/screens/auth/signup.dart` (`_step1`).
3. **Recovery-phrase step** — `app/lib/screens/auth/signup.dart`
   (`_step2`). The headline change of this work.
4. **Recovery-confirm step** — `app/lib/screens/auth/recovery_confirm.dart`.

Light polish, consistency only:

5. **Sign-in screen** — `app/lib/screens/auth/signin.dart`. Inherit the
   shared header/styling so it does not look orphaned next to the others.
   No structural redesign.

Out of scope:

- Pairing screen (already at the target quality bar; leave as-is).
- Home / inbox / conversation screens.
- Any change to identity, BIP39, key derivation, or server protocol. This
  is a presentation-layer change only. The generated phrase, the
  confirm-by-word-index mechanism, and all routing/state transitions in
  `_SignupFlow` / `_SigninFlow` stay exactly as they are.

## Design decisions

### Visual direction (validated via mockups)

Centered, greeting-style layout ("Warm Emblem" direction). A crafted
two-tone **heart emblem** anchors the welcome screen: one whole heart split
down the middle, the left half in `accentUser` (rose/pink), the right half
in `accentSage` (sage green) — "the two of you," one heart. A soft radial
glow sits behind it. Everything derives from the active palette, so it
reads correctly warm in both Light ("the hour the lamps come on") and Dark
("Deep Dusk").

### New reusable widgets

- **`HeartEmblem`** — a self-contained widget rendering the two-tone heart
  + glow. Painted with a `CustomPainter` (no new asset/dependency): one
  heart path, filled left-half `palette.accentUser` and right-half
  `palette.accentSage`, with a `RadialGradient` glow behind it tinted from
  `accentUser`. Size-parameterized. Pulls colors from `context.palette` so
  it themes automatically. Lives in `app/lib/onboarding/heart_emblem.dart`
  (new `onboarding/` folder).
- **`OnboardingHeader`** — a small shared widget rendering the optional
  step marker (e.g. "Step 1 of 2 · Recovery phrase", `accentSage`,
  uppercase annotation style) plus the title. Used by the phrase, confirm,
  and username screens to kill per-screen layout drift. Deliberately light:
  a step-marker + title block, not a framework. Lives in
  `app/lib/onboarding/onboarding_header.dart`.
- **`PhraseGrid`** — renders the 12 words as a 2-column grid of "chips,"
  each a rounded surface tile with a muted index number and the word in a
  monospace style. Lives in `app/lib/onboarding/phrase_grid.dart`.

These keep each screen small and let the styling live in one place.

### Welcome / choice screen

Centered column: `HeartEmblem`, "Little Love" title (display style), warm
lede, then a filled primary button (`accentUser` background) and an
outlined secondary. Replaces the current left-aligned headline + two
buttons. Keeps a privacy nod in the lede so we do not lose the existing
trust signal.

### Recovery-phrase step (the main fix)

- Step marker: "Step 1 of 2 · Recovery phrase".
- Title: "Save these 12 words".
- Warmer warning with a small key icon (`Icons.vpn_key` / `Icons.key`),
  tinted `accentUser`.
- Words in the **chip grid** (`PhraseGrid`), 2 columns, monospace, framed
  in a surface card.
- **"Copy all 12 words" button** (the requested fix): copies the
  space-joined phrase via `Clipboard.setData`, then shows a SnackBar with a
  brief security nudge.
- Primary CTA unchanged in behavior: "I've saved these words" → existing
  `onPhraseReady`.

### Username step + recovery-confirm step

Adopt the shared header/styling and warmer copy. Username step keeps its
field + validation (regex `^[a-z0-9_]{3,20}$`) and error text untouched.
Recovery-confirm keeps the words-3/7/11 verification and its error path
("That does not match — try again.") untouched; only the wrapper styling
and intro copy change. Confirm step shows "Step 2 of 2 · Confirm".

## Final copy (no em dashes, per project style)

- Welcome title: `Little Love`
- Welcome lede: `A tiny, private home for the two of you. No one else gets in.`
- Welcome primary: `Get started`
- Welcome secondary: `I have a recovery phrase`
- Phrase step marker: `Step 1 of 2 · Recovery phrase`
- Phrase title: `Save these 12 words`
- Phrase warning: `These 12 words are your key back in. Tuck them somewhere safe and private, just for the two of you.`
- Copy button: `Copy all 12 words`
- Copy SnackBar: `Copied. Paste it somewhere safe, then clear your clipboard.`
- Phrase CTA: `I've saved these words` (unchanged)
- Confirm step marker: `Step 2 of 2 · Confirm`
- Confirm intro: `Quick check. Type words 3, 7, and 11 so we know they landed safely.`

(`·` is a middle dot, not an em dash.)

## Copy button security note

Copying a recovery phrase to the clipboard is a small, accepted tradeoff:
other apps can read the clipboard and iOS may sync it via Universal
Clipboard. We accept this for the alpha for usability, and mitigate with
the SnackBar nudge to clear the clipboard. No auto-clear in this pass
(can revisit later).

## Error handling

No new failure modes. `Clipboard.setData` is fire-and-forget; the SnackBar
is shown optimistically after the call. All existing validation/error
paths (username regex, confirm mismatch, signin failure) are preserved
verbatim.

## Testing

- Widget test: recovery-phrase step renders 12 words and a copy button;
  tapping copy puts the joined phrase on the clipboard (pump a test
  `Clipboard` handler / assert via `SystemChannels.platform` mock) and
  shows the SnackBar.
- Widget test: `HeartEmblem` builds without error in both palettes.
- Smoke: existing signup-flow test (`phrase-saved` key, confirm flow)
  still passes unchanged — the keys and callbacks are preserved.
- Manual: build to both physical phones per project rules, verify both
  light and dark, verify copy actually lands on the iOS clipboard.

## Files

New:
- `app/lib/onboarding/heart_emblem.dart` (`HeartEmblem`)
- `app/lib/onboarding/onboarding_header.dart` (`OnboardingHeader`)
- `app/lib/onboarding/phrase_grid.dart` (`PhraseGrid`)

Modified:
- `app/lib/screens/auth/auth_gate.dart` (`_ChoiceScreen`)
- `app/lib/screens/auth/signup.dart` (`_step1`, `_step2`)
- `app/lib/screens/auth/recovery_confirm.dart`
- `app/lib/screens/auth/signin.dart` (light styling pass)

Unchanged (explicitly): identity/bip39, routing/state in
`_SignupFlow`/`_SigninFlow`, server calls, the confirm-by-index mechanism,
all widget keys used by tests.
