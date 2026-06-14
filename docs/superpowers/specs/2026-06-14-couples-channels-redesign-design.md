# LittleLove v0.4 — Couples Channels Redesign

**Date:** 2026-06-14
**Status:** Design approved; ready for implementation plan
**Mocks:** `mocks/v0.4/` (home-partner-dm, channel-switcher-open, channel-with-familiar, onboarding, create-channel)

## Summary

LittleLove is a "messenger for two." This redesign reframes the app's
information architecture around **channels** (topic rooms a couple shares),
while keeping the partner conversation as the front door. The goal is not to
change how messages render — bubbles stay — but to fix navigation so the app
reads as a small, intimate, channel-based space for exactly two people (plus
optional AI familiars).

This is an **IA / navigation redesign**, not a message-rendering redesign.

## Locked Decisions

1. **Home = partner DM.** Opening the app drops you straight into the partner
   thread. There is no inbox/list screen to cross first.
2. **Message style = chat bubbles.** Keep the existing left/right aligned
   bubbles from `conversation_page.dart`. No switch to a flat Discord-style
   list.
3. **Navigation = header channel switcher.** A pill in the top-left of the
   header shows where you are (partner or `#channel`); tapping the ▾ opens a
   dropdown of all channels. No persistent sidebar/rail on mobile.
4. **Familiars are participants, not channels.** Familiars (AI bots) are added
   *into* a channel at creation time. There are no solo-bot channels. Every
   channel is "you + partner + optional familiars."
5. **Pairing is required onboarding.** First run is signup → username → 12-word
   recovery phrase → **required** pairing with partner → land in partner DM
   home. You cannot reach the home screen solo.
6. **Clean first run.** After pairing, the only thread is the partner DM. No
   seeded starter channels; the channel feature is discovered via the
   switcher's "New channel" entry.

## Data Model Mapping

The existing room model already supports this; the redesign is mostly a
presentation/IA layer over it.

- **Rooms = channels.** Each room is a channel.
- **Partner thread** = the unnamed two-human `RoomShape.partner` room. It is
  pinned at the top of the switcher and is the home screen. It has no `#name`.
- **Channels** = named `RoomShape.chat` rooms containing both humans plus
  optional familiars (`botAccountIds`).
- **Familiars** = bot participants added via `botAccountIds` at channel
  creation. They are not rooms themselves.
- **`RoomShape.familiar` / the FAMILIARS bucket is effectively removed** from
  the user-facing model. (Solo-familiar rooms are no longer a first-class
  concept in the UI. Server enum may retain it; the client stops surfacing it
  as a navigation category.)
- **No pending-invite blank rooms after pairing.** Creating a channel adds the
  already-paired partner directly (both humans are implied members), so channel
  creation never produces a solo room with no others — the source of the
  earlier blank-room bug. The pending-invite path remains only for the initial
  partner pairing during onboarding.

## Information Architecture

```
App
└── Paired home (partner DM)         ← default route after auth+pairing
    ├── Header switcher (pill ▾)
    │   └── Channel dropdown
    │       ├── Partner thread (pinned, "YOU & <partner>")
    │       ├── Channels (named #rooms, with inline familiar names)
    │       └── + New channel  → create-channel bottom sheet
    └── Thread (bubbles) + composer
```

There is exactly one navigation surface: the header switcher. Selecting any row
swaps the active thread in place. The partner thread and every channel share
the same screen scaffold (header + thread + composer); only the header content
and the message stream differ.

## Components

### 1. Header channel switcher
- A rounded pill, top-left of the header.
- **Partner context:** partner avatar + name + `partner` sub-label.
- **Channel context:** `#` glyph + channel name + member sub-line
  (`you · <partner> · <familiar>`), plus a stacked member-avatar cluster on the
  right.
- A ▾ chevron indicates it's tappable. Tapping opens the dropdown.
- An E2E lock seal sits at the far right of the header (shrinks to a small lock
  so the header stays calm).
- Mock: `home-partner-dm.html`, `channel-with-familiar.html`.

### 2. Channel switcher dropdown
- Opens below the header over a dimming scrim.
- **Group 1 — "YOU & <partner>":** the partner thread, pinned at top, with a
  last-message preview.
- **Group 2 — "CHANNELS":** named channels. A channel with a familiar shows the
  bot name inline (`date-ideas + Garden`). Unread channels get a bold name + a
  dot.
- **Footer:** "+ New channel".
- Tapping a row or the scrim closes the dropdown (selecting a row also switches
  the active thread).
- Mock: `channel-switcher-open.html`.

### 3. Thread + composer (shared scaffold)
- Bubbles unchanged from current `conversation_page.dart`: right-aligned "me",
  left-aligned others; day separators; emoji-only large rendering; consecutive
  bubbles grouped.
- **Multi-party channels** add a small sender label above each non-self bubble
  (already supported for 3+ member rooms).
- **Familiar bubbles** use the sage `bubbleFamiliarBg` tint
  (`#EFEDDF` / border `#dfdcc4`) already in `twilight.dart`; partner bubbles
  stay white.
- Composer placeholder reflects context: "Message <partner>…" vs
  "Message #channel…".
- Mock: `home-partner-dm.html`, `channel-with-familiar.html`.

### 4. Create-channel bottom sheet
- Slides up over the current thread on "New channel".
- **Name field is focused immediately** (caret blinking, keyboard up) — no extra
  tap to start typing.
- **Auto-formats to lowercase-with-dashes** as the user types ("Date Ideas" →
  `date-ideas`); shows a live `#preview`.
- **Optional familiar picker** below: a checklist of the owner's familiars.
  Humans are implied (both partners are always members), so they are not listed.
- Primary button label reflects the name: "Create #date-ideas".
- On submit: create a `RoomShape.chat` room with `name`, both humans as members,
  and the selected `botAccountIds`. No pending-invite step (partner already
  paired).
- Mock: `create-channel.html`.

### 5. Onboarding flow (required pairing)
- Five steps: Welcome → Username → Recovery phrase → **Pair with partner** →
  Paired home.
- **Welcome:** "A messenger for two." with [Create an account] / [Sign in with a
  recovery phrase].
- **Username:** `^[a-z0-9_]{3,20}$`.
- **Recovery phrase:** show 12 words + "I've saved these words". No password
  reset.
- **Pair with partner (required):** show-my-code (QR + 4-word code) / enter-
  their-code toggle. Code expires in 10 minutes. The user cannot advance to home
  until pairing completes. This is the existing pending-invite / consume-invite
  pairing path.
- **Paired home:** lands directly in the partner DM with a "You and <partner>
  are paired" system line.
- Mock: `onboarding.html`.

## Flows

### First run
signup → pick username → save recovery phrase → pair with partner (hard gate)
→ partner DM home.

### Switch channel
tap switcher pill → dropdown → tap a row → thread swaps in place, dropdown
closes.

### Create a channel
switcher dropdown → "+ New channel" → bottom sheet → type name (auto-format) →
optionally check familiars → "Create #name" → new channel becomes the active
thread.

### Send a message
identical to current behavior, including optimistic local echo for outgoing
messages (server does not echo Send).

## Empty / Edge States

- **Just paired, no channels:** switcher shows only the pinned partner thread
  and "+ New channel". The CHANNELS group header may be omitted when empty.
- **Channel with no messages yet:** thread shows the day scaffold and an empty
  state; composer ready.
- **Solo room never reachable post-pairing:** because channel creation adds the
  partner directly, `displayName` never resolves to blank for a created channel.
  (The existing `displayName` guard returning "New chat" remains as a
  defensive fallback for the onboarding pending-invite partner room only.)

## Responsive Behavior

- **Mobile (primary):** single-pane. Header switcher is the only nav surface;
  channel list is the dropdown.
- **Wide / desktop (existing `inbox_shell` two-pane):** the existing
  sidebar/drawer can continue to list rooms; the switcher pill is redundant
  there but harmless. This redesign targets the mobile experience first; the
  wide layout keeps its current list-based nav and simply adopts the same
  channel/partner grouping and labels (partner pinned, channels below).

## Non-Goals

- Not changing message bubble rendering or the Twilight palette.
- Not building solo-familiar (bot-only) channels.
- Not adding roles, permissions, or 3+ human group channels — every channel is
  exactly two humans + optional familiars.
- Not adding push notifications, search, threads/replies, or reactions in this
  redesign.
- Not changing the server room/account schema beyond what already exists
  (rooms, members, names, bot account ids). No data migrations.
- Not redesigning the wide/desktop two-pane layout beyond label/grouping
  consistency.

## Open Items for Implementation Plan

- Exact route changes in `inbox_shell.dart` to make the partner room the default
  detail and to host the switcher.
- Where the switcher dropdown lives (overlay vs route) and how it reads the room
  list + unread state.
- Reuse of the existing create-room frame (`CreateRoomFrame {name,
  botAccountIds, inviteHumanPartner}`) for the new bottom sheet; for post-pairing
  channel creation `inviteHumanPartner` is not needed (partner already a member)
  — confirm server behavior for adding the existing partner to a new room.
- How familiars are enumerated for the picker (owner's bot accounts).
