# Pairing + Navigation Redesign — Design

**Date:** 2026-06-19
**Branch:** `worktree-pairing-nav-redesign`
**Issues:** #22 (nav refactor), #26 (pairing redesign), #16 (stale "Inviting partner…") — combined into one branch, sequenced #22 → #26, with #16 absorbed by #26.
**Platform:** iOS-only MVP.

## Summary

Replace the responsive drawer/shell signed-in chrome with an iOS-native
**list-as-home + push-to-chat** model (#22), then rebuild pairing on top of
it as a **single symmetric screen** backed by **roomless invites** and
**universal links** (#26). The roomless invite is the linchpin: it makes the
"room before a partner exists" dead-end — and the stale "Inviting partner…"
label (#16) — structurally impossible, because no room exists until the
partner consumes the invite.

These two efforts share one surface (Home's empty/pairing state) and one hot
spot (`room_message_router.dart`'s `RoomCreatedFrame` handler), which is why
they ride one branch. They are otherwise orthogonal: #22 is route lifecycle +
honest read-receipt timing; #26 is the pairing handshake + invite transport.

## Goals

1. **iOS-native navigation.** Home is the conversation list; tapping a room
   pushes a `ConversationPage` route; back pops to Home. "The chat is on
   screen" becomes a real widget lifecycle event (mount/unmount).
2. **Honest read receipts.** Inbound mark-read keys off a route-lifecycle
   `activeRoomProvider`, not the persistent `selectedRoomId` (which
   over-reports while the user glances at the list).
3. **No pairing dead-ends.** A single symmetric pre-pairing screen, reachable
   until paired. No room is created before a partner exists.
4. **Invite as one token, three forms.** Universal link, QR (= the link), and
   the existing 4-word code.
5. **Universal links on `littlelove.dev`,** served by the Axum backend.

## Non-goals

- No change to the wire protocol's message/encryption/store semantics, or to
  the read-receipt *protocol* (MarkRead / Read frames, double-heart
  rendering) — only to *when* the client decides a chat is "on screen."
- Desktop/tablet split-view stays deferred; the breakpoint machinery is
  **removed**, not reworked.
- **Pairing-interception hardening** (a leaked link/code lets someone pair as
  your partner — already true today with the 4-word code) — out of scope;
  revisit with a confirmation step later.
- A separate **"cancel/leave invite"** path — moot once invites are roomless
  (there is no solo room to leave).

## Background: how pairing works today (the problem)

(Verified against the current tree; file:line refs.)

- **Invite token.** A 4-word BIP39 code, dash-separated, 44 bits of entropy,
  carried in a 32-byte canonical token (`crypto/src/invite.rs:13`,
  `app/lib/pairing/bip39_invite.dart`). The 4-word string is URL-safe.
- **The pairing path mints a room.** `ShowInviteScreen` → `createInvite()` →
  `CreateRoom { inviteHumanPartner: true }`. With no partner, the server
  creates a room **bound to the invite** (`room_id` set) and returns it as a
  pending-invite room (`server/src/ws.rs:992`). So the solo-room state #26
  wants to delete is not an accidental misuse of "Create a chat" — the primary
  pairing path itself creates a room.
- **The dead-end (#26).** The pre-pairing card renders only at zero rooms.
  Any path that creates a room (the misplaced "Create a chat" channel flow, or
  even the invite flow) hides the card and strands the user.
- **Stale "Inviting partner…" (#16).** `PendingInvitesNotifier.clear()` is
  never called; the `RoomCreated` handler only ever `set`s. The sidebar/drawer
  render "Inviting partner…" whenever a pending entry exists, forever.
- **Consume requires a signature.** `ConsumeInviteFrame { code,
  signature_over_token }` — Ed25519 over `"littlelove.v0.2.invite-consume" ||
  0x00 || canonical_token` (`app/lib/pairing/invite_consume.dart:17`,
  verified server-side at `ws.rs:358`). A GET of an invite link cannot
  produce this signature, so a link **preview is inherently inert**.
- **The server already supports room-on-consume.** When `invite.room_id IS
  NULL` (legacy v0.2), `handle_consume_invite` creates the couple room on the
  fly (`ws.rs:358`). The roomless invite below reuses exactly this path.
- **Navigation today.** Raw `Navigator.push`/`pop`; `MaterialApp(home:
  AuthGate())`; no router package. `InboxShell` + `LayoutScaffold` swap a
  single detail pane by `selectedRoomId`. Only the `<600px` drawer branch ever
  runs on the target devices.
- **Backend.** Axum `Router` in `server/src/main.rs:63` serves REST + `/ws`
  only — no static files, no `.well-known`.
- **iOS.** `Runner.entitlements` has APNs + app groups; **no Associated
  Domains, no URL schemes**. `LLOVE_SERVER` env selects the API host.

## Part A — Navigation refactor (#22)

### Flow

```
WELCOME ──push──► SIGNUP ──push──► RECOVERY WORDS ──commit──► HOME
HOME (no partner) ──► symmetric pairing screen (empty state) ──partner joins──► HOME (paired)
HOME (paired) ──tap room / push──► CHAT ──‹ back / pop──► HOME
```

### Removed / collapsed

- `app/lib/inbox/layout_scaffold.dart` (`LayoutScaffold`) — delete.
- `app/lib/inbox/sidebar.dart`, `app/lib/inbox/navigation_rail.dart` — delete
  (desktop-only chrome).
- `app/lib/inbox/drawer.dart` (`DrawerContent`) — list content moves into
  `HomeScreen`; the `Drawer` wrapper is removed.
- `app/lib/inbox/channel_switcher.dart` (`ChannelSwitcher`) — delete (its only
  role beyond room-switching was the `ConversationPage` AppBar title).
- `app/lib/screens/inbox/inbox_shell.dart` (`InboxShell`) — delete;
  responsibilities move to `HomeScreen`.
- `InboxState.selectedRoomId` + `select()` / `deselect()` — remove. Active
  room is now route state. `InboxState` keeps `rooms` only; `setRooms` loses
  its keep-selection logic.

### Added / changed

- **`app/lib/inbox/active_room_provider.dart`** (new): `activeRoomProvider`, a
  `StateProvider<String?>` holding the roomId of the conversation currently on
  screen. Replaces `selectedRoomId` as the read-receipt signal.
- **`app/lib/screens/inbox/home_screen.dart`** (new, signed-in root): renders
  the room list (PARTNER / CHATS sections) or the empty/pairing state (Part B's
  symmetric screen); owns the `[+]` new-chat entry; keeps the router + outbox
  drain alive (`ref.watch(roomMessageRouterProvider)` /
  `ref.watch(outboxDrainProvider)`); owns navigation (tap → push
  `ConversationPage`; single-room auto-open; new-room push). The send/retry
  wiring (`_sendEncrypted`, `_retry`) currently in `InboxShell` moves here / to
  the push call site.
- **`app/lib/conversation/conversation_page.dart`**: becomes a pushed route.
  AppBar gets a back affordance and shows the room name (remove the
  `ChannelSwitcher` title + the now-unused `onNewChannel` param/import). In
  `initState` (post-frame) set `activeRoomProvider = room.roomId` and call
  `markRoomRead`; in `dispose` clear `activeRoomProvider` **only if it still
  equals this room**.
- **`app/lib/conversation/room_message_router.dart`**: gate the inbound
  mark-read on `ref.read(activeRoomProvider) == f.roomId` instead of
  `selectedRoomId` (currently `room_message_router.dart:219`). Remove the
  `selectAndMarkRead(ref, roomId)` call in the `RoomCreatedFrame` case
  (`:65`) — the router no longer drives navigation.
- **`app/lib/inbox/select_room.dart`**: `selectAndMarkRead` loses its
  `select()` call → rename to `markRoomRead`. `sendMarkRead` unchanged.
  Update callers (the sidebar/drawer/rail/switcher callers disappear with
  those files; the remaining caller is `ConversationPage` mount).
- **`app/lib/screens/auth/auth_gate.dart`**:
  `OutboxRehydrateGate(child: InboxShell(account: acc))` →
  `HomeScreen(account: acc)`.

### Single-room auto-open (IN)

When the room list first loads and exactly one room exists, `HomeScreen`
auto-pushes its `ConversationPage` (back still lands on Home). Implement via
`ref.listen(inboxStateProvider, ...)` + an initial post-frame check; guard
against double-push.

### Read-receipt lifecycle (the payoff)

| Event | Today (`selectedRoomId`) | After (route lifecycle) |
|---|---|---|
| Open a chat | `select()` + markRead + sendMarkRead | push → mount sets `activeRoom` + markRead + sendMarkRead |
| Inbound msg while chat open | mark read if `selectedRoomId == room` | mark read if `activeRoom == room` |
| Leave the chat | no event (id persists) | pop → `dispose` clears `activeRoom` → marking stops |
| Glance at the list | id persists → over-reports | chat unmounted → `activeRoom == null` → no over-report |

## Part B — Pairing redesign (#26), built on the new Home

### B1. Roomless invite (the linchpin) — backend

- New **`CreateInviteFrame`** (`kind: "CreateInvite"`) — or a `room: false`
  variant of the existing create path — that mints an invite with **`room_id =
  NULL`** and **creates no room**. Server returns the 4-word code + QR (the
  existing `qr_png_base64`, now over the link — see B3) + `expires_at`.
- The inviter holds this pending invite as **app state** (a provider), **not
  as an inbox room**. Nothing appears in the room list.
- On partner consume, the server takes the existing `room_id IS NULL` branch
  (`ws.rs:358`): it creates the couple room, fans out `RoomCreatedFrame` to the
  inviter and `InviteConsumedFrame` to the consumer. The room appears for the
  first time on both sides.
- **No migration:** the invite table's `room_id` is already nullable.
- **#16 resolved by construction:** there is no stale pending-invite *room* to
  mislabel. The inviter's pending-invite app state is cleared when the
  `RoomCreatedFrame` for the new room arrives. `PendingInvitesNotifier` (the
  room-keyed map) and its "Inviting partner…" rendering are deleted along with
  the sidebar/drawer.

### B2. Single symmetric pairing screen — app

- Lives as `HomeScreen`'s **empty state** (no rooms, no partner). Built
  directly here — we do **not** resurrect the old three-door `PairCard`.
- One screen shows **both**: "Here's your code" (link + QR + 4 words) **and**
  "Enter your partner's code." Whoever enters the other's code first completes
  the handshake.
- On mount, request a roomless invite (B1) and render its three forms.
- "Enter code" consumes via the unchanged signed `ConsumeInviteFrame` path.
- On partner join (`RoomCreatedFrame`), clear pending-invite state; Home is now
  populated (and single-room auto-open drops the user straight into the chat).
- Remove channel-creation from pre-pairing entirely. Channel/"new chat"
  creation lives only post-pairing in Home's `[+]` (where it already
  half-lives). `app/lib/screens/pair/show_invite.dart` and
  `app/lib/screens/pair/enter_code.dart` collapse into the symmetric screen;
  the `create_chat` pairing affordance is removed.

### B3. Invite transport — one token, three forms

- **Token in the path = the existing 4-word code**, dash-separated
  (URL-safe): `https://littlelove.dev/pair/abandon-pilot-react-zoo`.
- **Link** — text it; tapping opens the app and routes into the consume path.
- **QR** — now encodes the **full link** (replaces today's raw-code QR at
  `app/lib/pairing/qr.dart`), so the system camera opens the app. No in-app
  scanner is built.
- **4 words** — the same code, shown for copy/paste/read-aloud/accessibility.
- Consume still requires the app's Ed25519 signature, so a link preview
  (iMessage/Slack unfurl GET) is inert — no extra hardening needed.

### B4. Universal links — backend (Axum on `littlelove.dev`)

- Serve **`/.well-known/apple-app-site-association`** (JSON, correct
  content-type, no extension) with the app's `appID`
  (`<TeamID>.<bundleID>` → `9PVUX2535W.dev.littlelove.littlelove`) and the
  `/pair/*` path pattern.
- Serve a minimal **`/pair/:token`** web fallback page ("Open in LittleLove" /
  "Get the app") for when the app isn't installed. The GET is inert (no
  consume without a signature).
- Register both as new routes in `server/src/main.rs` (currently REST + `/ws`
  only).
- **Assumes** the prod `LLOVE_SERVER` is reachable at `https://littlelove.dev`
  with valid TLS (confirmed: Axum serves AASA on `littlelove.dev`).

### B5. Universal links — iOS

- Add the **Associated Domains** entitlement `applinks:littlelove.dev` to
  `app/ios/Runner/Runner.entitlements` (alongside existing APNs + app groups).
  Signing team is `9PVUX2535W` (per project memory).

### B6. Universal links — app deep-link handling

- Add a deep-link package (`app_links`) and handle an incoming
  `https://littlelove.dev/pair/<token>` (cold start + warm) → extract the
  4-word code → route into the symmetric screen's consume path (prefill +
  consume). If already paired, ignore/no-op gracefully.

## Implementation order (one branch, sequenced)

**Part A (nav):**
1. Add `activeRoomProvider`; wire `ConversationPage` mount/dispose (+test).
2. Migrate router inbound mark-read to `activeRoomProvider`; drop `RoomCreated`
   auto-select (+ port #20's three router tests to the new signal).
3. Strip `selectedRoomId`/`select`/`deselect` from `InboxState`; simplify
   `setRooms` (+test).
4. `select_room.dart` → `markRoomRead` (drop `select()`); update callers
   (+test).
5. `ConversationPage` → pushed route: back AppBar + room-name title, remove
   `ChannelSwitcher`/`onNewChannel` (+widget test).
6. `HomeScreen`: list + router/drain activation + send/retry wiring +
   tap-to-push (+widget test). Empty state stubbed until step 10.
7. Single-room auto-open + new-room push in `HomeScreen` (+widget test).
8. `AuthGate` → `HomeScreen`; delete `InboxShell`/`LayoutScaffold`/`Sidebar`/
   `NavigationRail`/`Drawer`/`ChannelSwitcher` + dead tests; full suite +
   format + analyze.

**Part B (pairing):**
9. Backend roomless `CreateInvite` path (new frame + handler branch; invite
   `room_id NULL`; no room) (+server test against `littlelove_test`).
10. Symmetric pairing screen as `HomeScreen`'s empty state (your code: link +
    QR + 4 words **and** enter-their-code); pending invite as app state; remove
    three-door card + pre-pairing channel creation; collapse
    `show_invite.dart`/`enter_code.dart` (+widget test). Delete
    `PendingInvitesNotifier` + "Inviting partner…" rendering (#16).
11. Confirm channel creation is post-pairing-only in Home's `[+]`.
12. Backend: serve AASA + `/pair/:token` web fallback from Axum (+test).
13. iOS: `applinks:littlelove.dev` Associated Domains entitlement.
14. App: `app_links` deep-link handling → route `/pair/<token>` into the
    consume path (+test where feasible).

## Testing

- **Nav/widget:** Home list renders rooms; tapping a row pushes
  `ConversationPage`; back pops to Home. Empty state shows the symmetric
  pairing screen when no rooms.
- **`activeRoomProvider` lifecycle:** mounting `ConversationPage` sets it;
  disposing clears it (only when still equal).
- **Router mark-read regating:** port #20's three tests
  (`room_message_router_test.dart`: selected / non-selected / replayed) to the
  `activeRoom` signal.
- **Single-room auto-open:** one room → conversation pushed on load, back lands
  on Home; two+ rooms → lands on the list.
- **Roomless invite (server):** `CreateInvite` mints an invite with no room;
  consume creates the couple room and fans out `RoomCreated`/`InviteConsumed`;
  the inviter never sees a pre-consume room. Run against `littlelove_test`,
  **never** the dev `littlelove` DB (`cargo test` truncates).
- **Symmetric screen (widget):** renders link + QR + 4 words and the enter-code
  field; consuming a code drives the handshake; partner-join clears pending
  state.
- **Deep link:** an incoming `/pair/<token>` routes into the consume path;
  already-paired is a graceful no-op.
- **Delete fallout:** remove tests bound to deleted widgets —
  `layout_scaffold_test.dart`, `drawer_test.dart`, `mobile_tap_targets_test.dart`
  (drawer-tile based), sidebar/navigation_rail/channel_switcher tests, and
  `switch_conversation_test.dart` if selection-based. Re-home still-relevant
  assertions onto `HomeScreen`. Remove pending-invite tests tied to the deleted
  room-keyed map.
- **Gate (run the full CI lint locally before push):** `cargo fmt` +
  `cargo clippy`, `dart format --output=none --set-exit-if-changed .`, full
  `flutter analyze` + `flutter test`. Per-file checks miss CI failures.

## Constraints / project rules

- **Migrations are schema-only** — and none is needed here (`room_id` already
  nullable).
- **Never test against the dev DB** — server tests use `littlelove_test`.
- **On-device testing** uses `./scripts/ios-deploy.sh --server <url>` to both
  physical phones (Court's iPhone 17 Pro Max + the iPhone 13 Pro Max), never
  Kaitlyn's, built one at a time.
- **Run the full CI lint locally before pushing.**

## Open questions

- **Single-room auto-open over a pushed sub-route:** when a modal (rename
  sheet, future settings) is pushed over the chat, `activeRoom` stays set;
  `dispose` is the only clear. Revisit with `ModalRoute.isCurrent` only if it
  causes a visible mismark. (Carried from #22; proposed answer: leave as-is.)
- **`CreateInvite` frame vs. flag:** prefer a distinct `CreateInviteFrame` over
  overloading `CreateRoom { inviteHumanPartner }` for clarity, but confirm
  during step 9 against the server's existing frame conventions.
