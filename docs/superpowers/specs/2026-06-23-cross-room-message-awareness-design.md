# Cross-room message awareness

**Date:** 2026-06-23
**Status:** Approved (design)

## Problem

A couple can have several rooms with each other (the unnamed partner DM plus
named topical "chat" rooms). While you're inside one conversation, there is no
in-app signal that your partner just messaged in a *different* room. The
per-room unread dot lives on the inbox, which you can't see from inside a chat,
and iOS silences push banners while the app is foregrounded — so other-thread
activity is effectively invisible until you back out to the inbox.

## What already exists (build on, don't rebuild)

- **Realtime delivery to all rooms:** `RoomMessageRouter`
  (`app/lib/conversation/room_message_router.dart`) listens to the live
  WebSocket and dispatches every incoming frame into its room's message store,
  whether or not that room is on-screen. It already distinguishes a *live*
  partner message landing in a non-active room from a *replayed* one, and
  auto-marks the **active** room read.
- **Unread state:** `app/lib/inbox/read_state_provider.dart` exposes
  `roomUnreadProvider` (per room), `anyUnreadProvider` (any room *other than the
  active one* unread — boolean), and `totalUnreadProvider` (count across all
  rooms, excluding own messages).
- **Active room:** `activeRoomProvider`
  (`app/lib/inbox/active_room_provider.dart`), set/cleared by
  `ConversationPage` init/dispose.
- **Inbox dot:** `ConversationListItem`
  (`app/lib/inbox/conversation_list_item.dart`) already renders an unread dot
  per room.
- **App shell:** single `MaterialApp` in `app/lib/main.dart`
  (`home: AuthGate()`), no `navigatorKey`/`builder` yet. Conversation routes
  are pushed on the root navigator from the inbox.

The gap is purely **surfacing** these signals on the conversation screen.

## Design

Two parts, both layering onto the above. Shipping together with the
keyboard/wallpaper polish on the same branch — this is one "make the chat
experience more polished" pass.

### Part 1 — Back-button unread count (always-there signal)

- **New provider** `unreadElsewhereCountProvider` in `read_state_provider.dart`:
  sums per-room unread across **all rooms except `activeRoomProvider`**. We
  exclude the active room explicitly (rather than reusing `totalUnreadProvider`)
  so a message arriving in the *current* room can't flicker the badge in the
  window before it auto-reads. Mirrors `anyUnreadProvider`'s exclusion logic but
  returns an `int`.
- **UI:** the existing AppBar `leading` back pill in `conversation_page.dart`
  gains a small red count badge (Telegram/WhatsApp style), `9+` cap, hidden at
  zero. Tap behavior is unchanged (`maybePop` → inbox, where the per-room dot
  shows *which* thread).

### Part 2 — In-app banner on arrival (can't-miss-it nudge)

- **Event source:** in `RoomMessageRouter`, on the existing *live + non-active +
  not-self* branch, additionally publish a banner event to a new
  `incomingBannerProvider` (a small `StateNotifier` holding the latest event or
  null). Event payload: `{ roomId, roomName, preview, msgId }`.
  - Guards: live only (no banner storm on reconnect replay), never self-copies,
    never the active room.
  - Content is decrypted **client-side** (the client holds the room key, unlike
    the content-free server push), so `preview` is a real short snippet.
- **Surface:** a banner host mounted once at the app shell via
  `MaterialApp.builder`, watching `incomingBannerProvider`. It slides a banner
  down from the top ("💬 <room name> · <preview>"), auto-dismisses after ~4s,
  swipe-up to dismiss early. Independent of the current route.
- **Tap routing:** push that room's `ConversationPage` onto the root navigator
  (back returns to where you were), matching Telegram. Requires a root
  `navigatorKey: GlobalKey<NavigatorState>` added to the `MaterialApp` so the
  overlay can navigate from outside the widget tree.

## Components & boundaries

| Unit | Responsibility | Depends on |
| --- | --- | --- |
| `unreadElsewhereCountProvider` | "How many unread in rooms other than the one I'm in?" | room list, `roomUnreadProvider`, `activeRoomProvider` |
| Back-button badge (in `conversation_page.dart`) | Render count over the existing back pill | `unreadElsewhereCountProvider` |
| `incomingBannerProvider` | Hold the latest "message in another room" event | — |
| Router hook | Emit a banner event on the live/non-active/not-self branch | `activeRoomProvider`, room name lookup |
| Banner host (app shell) | Animate, auto-dismiss, route on tap | `incomingBannerProvider`, root navigator key |

## Error / edge handling

- Active room or self-message → no badge contribution, no banner.
- Reconnect replay/backfill → no banner (live-only guard).
- Rapid arrivals → banner shows the latest and resets its timer (no stacking).
- Badge at zero → no badge drawn.
- Tapping a banner for a room already in the stack → push anyway (simple; few
  rooms make stack depth a non-issue).

## Testing

- **Part 1:** widget test — another room unread → back button shows the count;
  zero → no badge. (Conversation tests already drive providers.)
- **Part 2:** extend `app/test/conversation/room_message_router_test.dart` —
  assert a banner event fires for a live non-active partner message and does
  *not* fire for self-copy / active-room / replayed message. Plus a widget test:
  banner renders on event and navigates on tap.

## Out of scope

- Last-message preview / timestamp on inbox rows (separate enhancement).
- Changing the server push (stays content-free).
- The "different tab" interpretation (Voice tab etc.) — this is about separate
  rooms.
