# Delete channel

Date: 2026-11-01. Mockups: https://claude.ai/artifact/RZ2uNT7SLmd6dJkmnxNDKv
(five phone screens, dark Twilight theme: chat info with the new row, the
type-to-confirm sheet empty and filled, your inbox after, Kaitlyn's inbox
after).

Calls marked **(Claude's call)** were made while designing and have not been
explicitly confirmed by Court; everything else was agreed in conversation.

## Why

Channels have Create (the New channel sheet), Read (inbox, chat) and Update
(rename, channel picture), but no Delete. The server half-exists: a
`LeaveRoom` frame removes *you* from a room and only deletes the room when the
last member leaves (`server/src/rooms.rs` `leave_room`,
`server/src/ws.rs` `handle_leave_room`). The app defines `LeaveRoomFrame` but
never sends it. "Leave" is a group-chat idea; every room here is exactly the
two partners, so leaving would strand the other person in a one-member
channel that nobody receives.

Court wants either partner to be able to delete a channel, gone for both of
them.

## Goals

- Either partner can delete any **channel** (a named room). The channel and
  all its messages are removed for both partners, permanently.
- Deleting takes a deliberate step: the confirmation sheet asks you to type
  the channel's name before Delete enables.
- The deleter lands back on the inbox with a "Channel deleted" toast.
- The partner gets **no alert or notification**. The channel simply leaves
  their inbox. The one exception: if they are *inside* that channel when it
  is deleted, they are taken back to the inbox with a toast "Court deleted
  Travel" so the screen doesn't vanish without explanation.
- Every trace of the channel is cleared from both phones: inbox row, messages,
  search index, draft, read state, unread count, pending sends.
- A partner who was offline loses the channel the next time they connect.

## Non-goals

- **Archive / hide / "delete in 30 days".** Considered and declined for now
  as too much work at this scale; the confirmation is the safeguard. Room is
  left for archive later (see "Leaving room for archive").
- **Undo.** No undo toast, no grace window. Deletion is final.
- **Deleting the partner chat** (the unnamed room). It is the couple's main
  chat; unpairing is a separate concern.
- **Deleting the encrypted attachment blobs** in R2. The API server never
  talks to the blob store directly (it only signs URLs), so blobs from a
  deleted channel stay behind, unreadable without the room key. Open a
  follow-up issue for blob cleanup.
- **Changing `LeaveRoom`.** It stays as it is (unused by the app).
- Group / 3+ member semantics (out of scope for the whole app).

## Anti-goals (a failure even if it works)

- One partner able to delete the **partner chat**, or any room they aren't a
  member of. The server enforces both; a hidden button is not enforcement.
- A channel that "comes back": deleted on one phone, still in the other's
  inbox, or reappearing after a reconnect or relaunch.
- Plaintext from a deleted channel lingering on either phone (search index,
  drafts, notification previews, cached decrypted media).
- Deleting with a single accidental tap.
- A "Channel deleted" toast when nothing was deleted (offline, server error).

## What it looks like

All copy below is final unless marked. No em dashes in copy.

### Chat info page (`conversation/chat_info_page.dart`), channels only

Below the "THIS CHAT" section and above the encryption note, a new card on its
own (an `InfoSection` without a caption): one row, `Icons.delete_outline` and
the label **Delete channel**, both in `palette.warningTone`, **no chevron**.
**(Claude's call: its own card rather than a row under "Rename chat", so it
isn't one slip away from Rename, like the iOS Settings convention.)** The row
is absent for the partner chat (`onDeleteChannel` null, the page's existing
"null callback hides the affordance" pattern).

### Confirmation sheet (new, `conversation/delete_channel_sheet.dart`)

Modelled on the New channel sheet (`screens/create_chat/create_channel_sheet.dart`):
`showModalBottomSheet`, `isScrollControlled`, `bgCanvas`, top radius 24,
lifted by the keyboard, padding 22/12/22, grabber 42×5 `borderSoft`.

- Title (23, w600): **Delete Travel?** (the channel's name).
- Body (13, `textMuted`): **This deletes the channel and all its messages for
  both of you. This can't be undone.**
- Prompt (13, `textMuted`, name in `textPrimary` w600): **Type Travel to
  confirm**.
- A row: the channel's 44px tile **(Claude's call, so you can see which
  channel)**, then a borderless text field, hint **Channel name**, autofocus,
  17px w500. A `borderSoft` divider below.
- A full-width 50px stadium button **Delete channel**. Disabled (Material 3
  disabled colours) until the typed text matches; enabled it is filled
  `warningTone` with a dark label (`#2A0F1C`-ish on the dark palette, white on
  the light one, whichever clears 4.5:1; check in `palette_contrast_test`).
- A **Cancel** text button (17, `accentUser`) under it. **(Claude's call: the
  New channel sheet has none, but a destructive sheet gets a visible way
  out.)**

**Matching rule:** trim both sides, compare case-insensitively
(`toLowerCase()`). "travel" matches "Travel". No other normalisation: an
emoji in the name must be typed. **(Claude's call, agreed in spirit by
Court: a deliberate step, not a spelling test.)**

Tapping Delete: medium haptic (matches the message delete actions shipped in
#113), the button shows a spinner and the field locks while waiting for the
server (see "Flow"). On success the sheet and the chat-info page and the
conversation all pop to the inbox and `showLoveToast(context, 'Channel
deleted', icon: Icons.check)`. On failure the sheet stays open and a SnackBar
says **Couldn't delete the channel. Try again.** **(Claude's call on copy and
on spinner-until-confirmed; see "Flow" for why.)**

### Inbox

The row disappears. Nothing else changes.

### Partner inside the deleted channel

If the partner has that channel open (the conversation page, its chat info,
shared media, or any sheet over them), the app pops everything back to the
inbox and shows `showLoveToast(context, '<Name> deleted <Channel>', icon:
Icons.delete_outline)`, e.g. **Court deleted Travel**. `<Name>` is the
partner's display name as the app already shows it; `<Channel>` is the room
name the app held before removal. A half-typed draft is discarded with the
channel. If the partner is anywhere else, nothing is shown.

## How it works

### Wire (mirror in `server/src/wire.rs` and `app/lib/wire/frames.dart`, round-trip tests both sides)

- Client → server: `{"kind":"DeleteRoom","room_id":"<id>"}`.
- Server → client: `{"kind":"RoomDeleted","room_id":"<id>","deleted_by":"<username>"}`.
  `deleted_by` lets each phone tell "I did this" from "my partner did this"
  (toast copy), and is the authenticated deleter's username, never taken from
  the request.
- The existing `Error { code, message }` frame gains an **optional
  `room_id`**, filled in at least by the delete handler. Without it the
  deleter's sheet can't tell its own `UNKNOWN_ROOM` / `RATE_LIMITED` from an
  error caused by another frame in flight, and could show "Channel deleted"
  when nothing was deleted. Optional, so other handlers and old builds are
  unaffected. **(Claude's call.)**

### Server

`handle_delete_room(&state, &me, &room_id, &tx)` in `ws.rs`, following
`rust.md § WebSocket handlers`:

1. Rate-limited with a per-connection `WindowRateLimiter` (a new frame that
   does DB work and fans out). Limit is the builder's call; deletes are rare.
2. `is_member(room_id, me.id)` else `UNKNOWN_ROOM` (don't leak existence).
3. Refuse the **partner chat**: the unnamed room (the app's `RoomShape` rule:
   a room with no name is the partner DM). Reply with an error code per
   `rust.md § Errors` (a new constant, e.g. `CANNOT_DELETE_ROOM`).
   Enforced here, not just by the hidden row.

   That check only holds if the partner chat can't be given a name. Today
   `handle_rename_room` lets any member rename any room (only the app hides
   Rename on the partner chat), so a crafted `RenameRoom` + `DeleteRoom`
   would delete it. The partner is treated as able to craft frames (root
   `CLAUDE.md`, "authorize at the apply layer"), so close both doors:
   **`RenameRoom` refuses to name an unnamed room**, and **`CreateRoom`
   refuses an empty name** (so no unnamed channel can exist that could never
   be deleted). Confirm pairing doesn't create the partner chat through
   `CreateRoom` before adding that check. **(Claude's call: the small fix,
   no new column.)**
4. Read the member list, then in **one transaction** delete the room
   (`rooms.rs`, new `delete_room(pool, room_id)`); foreign keys cascade
   everything hanging off it.
5. After commit, deliver `RoomDeleted { room_id, deleted_by: me.username }`
   to **every** member, the deleter included (it is the deleter's
   confirmation). No APNs/VoIP push: an offline partner learns from the next
   `Rooms` list.

**Required schema fix (found during design):** `messages.room_id` was added in
`server/migrations/0005_alter_messages.sql` as `REFERENCES rooms(id)` with
**no `ON DELETE CASCADE`**, so deleting any room that has messages fails
with a foreign-key violation today. (`leave_room`'s doc comment claims
messages cascade; it's wrong, and its test only deletes an empty room.) Add a
**schema-only** migration that drops and re-adds that constraint with
`ON DELETE CASCADE` (default name `messages_room_id_fkey`; confirm the real
name). Then audit every other `REFERENCES rooms` (`0004` room_members,
`0006` invites, `0011` attachments already cascade) and anything keyed by
`room_id` without a foreign key (read markers, push, channel pictures,
calls) so nothing is left behind or blocks the delete. Fix `leave_room`'s
comment. Per root `CLAUDE.md`: no data statements in the migration.

### App: flow on the deleter's phone

The server's `RoomDeleted` is the durable step, so the toast waits for it
(REVIEW.md §5, honest UI):

1. No live connection: SnackBar **You're offline. Connect to delete this
   channel.** and the sheet stays open. **(Claude's call.)**
2. Otherwise send `DeleteRoom` and wait (spinner) for `RoomDeleted` for that
   room, or an error frame for it, with a timeout (builder's call, ~10 s)
   that ends in the failure SnackBar.
3. On `RoomDeleted`: run the shared removal (below), pop to the inbox, show
   "Channel deleted".

Not optimistic, because an optimistic local delete that the server never
performed would have the channel reappear on the next `Rooms` list.

### App: applying `RoomDeleted` (both phones)

One function used for the live frame and the reconnect sweep. Split into two
steps on purpose (see "Leaving room for archive"):

- **Hide:** remove the room from `inboxStateProvider`; if it is the open /
  active room, pop to the inbox (and toast, per above, when `deleted_by` is
  the partner).
- **Purge:** wipe every local trace of the room:
  - `MessageDb`: its `messages` rows (the FTS delete trigger drops the search
    entries; also run the FTS cleanup the way `clear()` does if needed),
    `room_sync`, `drafts`; per-message side tables keyed by those message ids
    (`tombstones`, `pending_edits`, `deleted_for_me`) for ids in that room.
    New `MessageDb.purgeRoom(roomId)` and `MessageDb.roomIds()`.
  - In-memory: `messageStoreProvider(roomId)`, `roomHydratedProvider`,
    typing, `pendingChannelActions`, room key cache (`invalidate`).
  - Outbox rows for the room (they'd fail forever with `UNKNOWN_ROOM`).
  - Read state for the room (`readStateProvider` / store), so the badge
    recomputes.
  - Per-room prefs (the chat's wallpaper choice, if stored per room) and the
    channel picture cache.
  - Decrypted attachment cache files for that room's messages (map the
    room's `attachment` descriptors to cache paths before deleting the rows).
  - Delivered notifications for that room, if the app can remove them.

### App: partner offline at delete time

On every `RoomsFrame` the app already replaces the inbox list (`setRooms`), so
the row disappears. Add a sweep: any room id present locally
(`MessageDb.roomIds()`) but absent from the server's list is purged with the
same Purge step. No toast on this path.

The sweep is only safe if the list is trustworthy, because not everything it
would wipe can be rebuilt: unsent outbox rows, drafts and Delete for Me ids
(#113) live only on the phone. Today the server sends `Rooms { rooms: [] }`
when `list_rooms_for_account` fails (`ws.rs`, connect), so a database hiccup
would wipe every room. Two guards, both required **(Claude's call)**:

1. **Server:** on a room-list failure at connect, close the socket (the app
   already reconnects with backoff) instead of sending an empty list.
2. **App:** skip the sweep when the list is empty or doesn't contain the
   partner chat. A paired account always has its partner chat, so a list
   without it is wrong, not a deletion.

### Races (builder must handle; tests for each)

- A message, reaction, edit or typing frame for the room arriving after
  `RoomDeleted` must not resurrect it (no inbox row, no DB rows). Keep a
  session set of deleted room ids and drop frames for them, like the
  per-message sets in `MessageStore`.
- The partner sends into the room while it is being deleted: the server
  answers `UNKNOWN_ROOM`; the outbox must drop that row, not retry forever.
- Both partners delete at once: the second gets `UNKNOWN_ROOM`; treat a
  pending delete that gets `UNKNOWN_ROOM` **carrying the same `room_id`** as
  success (the room is gone either way). An error without a matching
  `room_id` is not about this delete.
- A call in progress in the channel (if calls can be channel-scoped): end it.

### Profiles live in a room too

`coupleRoomFor` (`app/lib/profile/profile_service.dart`) picks the couple's
**lowest-id** shared room for the profile envelope (encrypted with that
room's id) and the avatar's attachment row; migration `0014` clears
`avatar_key` when that room is deleted. If that room were a channel,
deleting it would leave the partner unable to read the owner's profile and
the avatar broken (`ensureAvatarUploaded` keeps reusing a descriptor whose
attachment row is gone).

Fix: **pin the profile room to the partner chat** (the unnamed room, which
can't be deleted), falling back to lowest id only before one exists.
`coupleRoomFor` is used by the sender and the receiver, so both move
together once both phones run the build; the profile is already republished
on every connect, so any couple whose oldest room wasn't the partner chat
self-heals on the next connect. For most couples the partner chat already
is the oldest room (it's created at pairing), so nothing changes. Builder:
confirm the receiver resolves the room through the same function, and drop
the cached avatar descriptor if its room no longer exists. **(Claude's
call.)**

## Rollout

Ship the app build to **both phones first** (TestFlight), then deploy the
server. An old build ignores `RoomDeleted` and has no sweep: the row would
leave its inbox on reconnect, but the channel's messages would stay in its
local database. With two users, a release order is enough; no minimum-version
gate. An app build talking to the old server gets an error back for the
unknown `DeleteRoom` frame and shows the failure SnackBar. **(Claude's
call.)**

## Leaving room for archive

Court asked that an archive strategy stay possible later. Three choices keep
it open:

1. **Delete is its own frame and a hard delete.** No `deleted` flag on rooms.
   Archive later is additive: `ArchiveRoom`/`UnarchiveRoom` frames and one
   nullable `archived_at` column (schema-only).
2. **Hide and Purge are separate app functions.** Archive would reuse Hide
   and skip Purge.
3. **The bottom card on chat info** can take an "Archive channel" row (normal
   tone) above "Delete channel"; the inbox can grow an "Archived" row under
   the channels.

## Unread, badge, push, search

- Server: the room's messages go, so the partner's server-side unread count
  drops by itself; the next badge sync reflects it.
- App: read state and unread for the room are purged; the badge recomputes.
- No push for a delete. Already-delivered notifications for the room should
  be removed if the platform allows (builder checks what the app does today).
- Search: purged rows leave the FTS index.

## Sign-out

No new persisted store. `MessageDb.purgeRoom` is a subset of `clear()`. If the
builder adds any new pref or table (e.g. a persisted deleted-room set), it
must be wiped in `identity/sign_out.dart` per `dart.md § Persistence`.

## Crash reporting

Constant `reportFault` contexts only, e.g. `room_delete`, `room_purge`. Never
the room name. `deleted_by` is a username: if it's ever logged, it's a
structured field, and added to both scrub lists if it's a new key.

## Testing

- **Server:** `delete_room` with messages, attachments, invites and members
  (fails today without the migration); non-member gets `UNKNOWN_ROOM`; the
  partner room is refused; renaming the partner room and creating an
  unnamed room are refused; both members receive `RoomDeleted`; rate limit
  replies `RATE_LIMITED`; the delete handler's errors carry `room_id`; a
  room-list failure at connect closes the socket; wire round-trip for all
  changed frames.
- **App, guards:** the sweep is skipped for an empty list or one missing
  the partner chat; the profile room resolves to the partner chat even when
  a channel has a lower id.
- **App:** frames round-trip; Purge leaves no rows for the room in any
  `MessageDb` table (including FTS), no draft, no outbox rows, no read
  state; the reconnect sweep purges a room missing from `Rooms`; a late
  frame after `RoomDeleted` doesn't resurrect it; the partner inside the
  channel is popped with the right toast, the partner elsewhere sees
  nothing; the deleter's toast waits for `RoomDeleted` and a failure keeps
  the sheet open; the confirm button enables only on a trimmed,
  case-insensitive match; the row is absent for the partner chat.
- **On device:** two phones (or `scripts/sim-couple.sh`): delete from one,
  watch the other inside and outside the channel; delete while the other is
  offline, then reconnect.

## Left to the builder

- Rate-limit numbers, timeout length, the new error-code name.
- Exact constraint name in the migration and the audit of room-keyed data.
- How the deleter's sheet waits for `RoomDeleted` (a completer keyed by room
  id in the router, or similar).
- Whether a persisted set of deleted room ids is needed beyond the session
  set (the guarded reconnect sweep should make it unnecessary; if one is
  added, sign-out wipes it).
- Whether removing delivered notifications is feasible.
