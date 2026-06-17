# Double-heart read receipts — design

**Date:** 2026-06-16
**Status:** Approved, ready for implementation plan

## Goal

When your partner opens a chat, every message you sent that they hadn't yet
seen flips from a single heart (*sent*) to a **double heart** (*read*). The
indicator is per-message and persists across app restarts. It is symmetric:
the same happens to your partner's messages when you open the chat.

This is the first true read signal in the product. Today `sent` only means
"the server echoed the message back" — there has never been a delivery or read
acknowledgement on the wire. The visual was already designed in
`mocks/v0.4/message-status.html` and explicitly deferred to "a separate PR that
needs a read-receipt frame end-to-end." This is that PR.

## Constraints / context

- **Couples-only.** Every room contains exactly the two partners. "The
  recipient" is always a single unambiguous person — no group / all-vs-some
  read semantics anywhere.
- **Migrations are schema-only** (per CLAUDE.md). No data UPDATE/INSERT/backfill
  in migration files.
- Messages are stored **one row per recipient**: `messages` has composite PK
  `(id, recipient_account_id)`, columns `id, room_id, from_account_id,
  recipient_account_id, body, ts`. The same logical message is N rows (here,
  always 2 — sender self-copy + partner copy).
- Message ids are ULIDs (lexicographically time-sortable), so "everything up to
  id X" is a clean `id <= X` range.

## Behavior

- **Trigger:** read fires when the recipient *opens the chat/channel* — not on
  per-bubble scroll visibility. On open, everything currently delivered becomes
  read at once.
- **Granularity / display:** per individual message. Every read message shows
  its own double heart. No collapsing to a trailing message (matches the
  existing per-bubble marker rendering in `_bubbleBody`).
- **States:** `sending` (clock) → `sent` (single heart) → `read` (double
  heart). `read` only ever applies to your own outgoing messages. `failed` is
  unchanged (collapsed caption below the run).

## Data model (server)

One nullable column, schema-only:

```sql
-- migration: ADD COLUMN, nullable, no backfill
ALTER TABLE messages ADD COLUMN read_at timestamptz;
```

Each recipient's row records when *that recipient* read the message. A message
you sent is "read" when the partner's row for that `id` has `read_at` set. An
index supporting the mark-read range update and the replay lookup:

```sql
CREATE INDEX messages_recipient_unread_idx
  ON messages (recipient_account_id, room_id, id)
  WHERE read_at IS NULL;
```

## Wire protocol

Two new frames, plus one field on the existing `Message` frame.

### Client → server: `MarkRead`
```
{ "kind": "MarkRead", "room_id": "...", "up_to_message_id": "<ULID>" }
```
Sent by the recipient's client when it opens a chat. `up_to_message_id` is the
highest message id the client currently holds for that room.

Server handling:
1. `UPDATE messages SET read_at = now() WHERE recipient_account_id = <me>
   AND room_id = $room AND read_at IS NULL AND id <= $up_to AND
   from_account_id <> <me>` — returning the affected `id`s and their
   `from_account_id`. (Excludes the reader's own self-copies.)
2. Group the returned ids by sender and relay a `Read` frame to each sender's
   open sessions via the existing `Routing::deliver`.

This UPDATE lives in application code (the WS handler), **not** in a migration —
the schema-only rule applies to migration files, not runtime queries.

### Server → sender: `Read`
```
{ "kind": "Read", "room_id": "...", "message_ids": ["<ULID>", ...],
  "reader": "<username>" }
```
The specific message ids that just flipped. The sender's client marks each one
individually → a double heart on each acknowledged bubble.

### `Message` frame gains `read: bool`
```
{ "kind": "Message", ..., "read": true }   // omitted when false
```
On `Subscribe` replay, for each message the subscriber *sent*
(`from_account_id = me`), the server sets `read: true` when the partner's row
for that id has `read_at IS NOT NULL`. This is what makes double hearts survive
an app restart. Serialized like `replayed`: skipped when false.

## Client

### Model
- `SendStatus` enum (`wire/message.dart`) gains `read`.
- `Msg.fromJson` reads the optional `read` field; a replayed message with
  `read: true` is constructed with `sendStatus: SendStatus.read`.

### Inbound `Read` frame
- Parsed in `frames.dart` as a new `RoomServerFrame` variant (`ReadFrame` with
  `roomId`, `messageIds`, `reader`).
- The connection handler looks up each id in the room's message store and flips
  `sendStatus` → `SendStatus.read` (a `markRead(messageIds)` on the message
  store notifier, analogous to the existing `updateStatus`).

### Outbound `MarkRead` frame
- `MarkReadFrame` added to `frames.dart` outbound section with `toJson`.
- Sent at the existing chat-open hook. `select_room.dart:12` already calls the
  local `readStateProvider.markRead(roomId)`; alongside it, dispatch the wire
  `MarkRead` with the highest known message id for that room. (If the room has
  no messages from the partner, skip — nothing to ack.)

### UI marker
- `_Marker` enum (`conversation_page.dart:45`) gains `read`.
- `_statusModel` maps `SendStatus.read` → `_Marker.read`.
- `_markerWidget` renders the double heart from a new asset
  `assets/icons/heart-read.svg`, rendered **without** a `colorFilter` (the asset
  is two-tone, so a single srcIn filter would flatten it).

### Asset: `assets/icons/heart-read.svg`
Lifted directly from `mocks/v0.4/message-status.html` (the `.heart.read` SVG,
`viewBox 0 0 50 29`, two paths). Both fills baked in:
- right heart (`h2`): `#A04A6A` (= `TwilightColors.accentUser`)
- left heart (`h1`): `#C98EA3` (lighter — the "two of us" tint)

## Symmetry

Fully symmetric and falls out of the design for free: both clients send
`MarkRead` on open and both render `Read`. When you open the chat your partner's
sent messages get double hearts on *their* device, and vice-versa.

## Testing

**Server (Rust):**
- `wire.rs`: serde round-trip for `MarkRead` (parse), `Read` (serialize),
  `Message` with `read: true`/omitted-when-false.
- Mark-read query: opening marks only the reader's unread partner-sent rows in
  that room with `id <= up_to`; self-copies and already-read rows untouched;
  returns the right ids grouped by sender.
- Replay: a `Subscribe` after the partner has read returns the sender's messages
  with `read: true`; unread ones omit it.
- Routing: `Read` is delivered to the sender's open sessions.

**Client (Dart):**
- `Msg.fromJson` parses `read` → `SendStatus.read`.
- `frames.dart` parses an incoming `Read` frame; builds a `MarkRead` `toJson`.
- Message store `markRead(ids)` flips matching messages to `SendStatus.read`.
- `conversation_page` status model maps `SendStatus.read` → `_Marker.read` and
  `_markerWidget` renders the double-heart asset (golden / key `status-heart`
  variant, e.g. `status-double-heart`).
- Opening a room dispatches `MarkRead` with the correct `up_to_message_id`.

## Out of scope (YAGNI)

- Per-character/scroll-based read tracking (open = read all).
- A read-receipts on/off toggle (always on for now).
- Typing indicators / presence (separate concerns).
- Syncing read state across the *reader's* own devices beyond what the
  server-side `read_at` already gives for free.
