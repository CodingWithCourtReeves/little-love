# Delete Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Either partner deletes a channel for both, after typing its name; both phones drop every local trace.

**Architecture:** A new `DeleteRoom` client frame hard-deletes the room in one transaction (after a schema fix so messages cascade) and fans `RoomDeleted` to both members. The app waits for that frame before confirming, applies it through one Hide + Purge path (also used by a guarded reconnect sweep), and pops whoever is inside the channel back to the inbox.

**Tech Stack:** Rust (axum, sqlx, Postgres), Flutter/Dart (Riverpod 2, sqflite/SQLCipher).

**Spec:** `docs/superpowers/specs/2026-11-01-delete-channel-design.md`

## Global Constraints

- Postgres migrations are schema-only: no `UPDATE`/`INSERT`/`DELETE`/`DO $$` (root `CLAUDE.md`).
- Every error code sent to a client is a constant in `wire::error_codes`; new frames mirrored in `server/src/wire.rs` and `app/lib/wire/frames.dart` with round-trip tests on both sides.
- Server DB tests use `#[file_serial(db)]` and run against `littlelove_test`, never the dev DB (`rust.md § Gate`).
- App copy, verbatim: sheet title `Delete <Name>?`; body `This deletes the channel and all its messages for both of you. This can't be undone.`; prompt `Type <Name> to confirm`; hint `Channel name`; button `Delete channel`; `Cancel`; row `Delete channel`; toasts `Channel deleted` / `<Partner> deleted <Name>`; SnackBars `You're offline. Connect to delete this channel.` / `Couldn't delete the channel. Try again.` No em dashes.
- Match rule: `typed.trim().toLowerCase() == name.trim().toLowerCase()`.
- Run CI gates with the CI Flutter SDK (`~/actions-runner/_work/_tool/flutter/stable-3.44.9-arm64/flutter/bin`); revert local SDK churn (`pubspec.lock`, `analysis_options.yaml`, iOS project files) before committing.

## Review Focus

1. A frame for the room (message, read, typing, rename) arriving just after `RoomDeleted` must not re-create its inbox row or DB rows. Test in Task 6.
2. A `Rooms` list that is empty or lacks the partner chat must not wipe anything. Test in Task 6.
3. An unrelated error (no or different `room_id`) arriving while the sheet waits must not be read as the delete's result. Test in Task 7.
4. Renaming a channel to an empty name would make it look like a second, undeletable partner chat; the server must refuse it. Test in Task 3.
5. The deleter who is not inside the channel (e.g. the sheet was dismissed) still sees the inbox update; the toast is only for whoever was inside. Test in Task 7.

---

### Task 1: Messages cascade with their room; `delete_room`

**Files:**
- Create: `server/migrations/0017_messages_room_cascade.sql`
- Create: `server/tests/migration_0017_schema.rs`
- Modify: `server/src/rooms.rs` (new fn; fix `leave_room` doc comment)
- Test: `server/tests/room_mutations.rs`

**Interfaces:**
- Produces: `pub async fn delete_room(pool: &PgPool, room_id: &str) -> sqlx::Result<bool>` (true if a row was deleted).

- [ ] **Step 1: Failing store test** in `room_mutations.rs` (`#[serial]`, matching that file): `delete_room_removes_room_with_messages_attachments_and_members` seeds a couple room via `seed_couple_room`, inserts one `messages` row and one `attachments` row for it, calls `delete_room`, asserts it returns `true` and `SELECT COUNT(*)` is 0 in `rooms`, `room_members`, `messages`, `attachments` for that room id. Also `delete_room_on_missing_room_returns_false`.
- [ ] **Step 2: Run, expect FAIL** (`delete_room` undefined; once stubbed, FK violation `messages_room_id_fkey`).
  Run: `( source ../scripts/dev-env.sh; export DATABASE_URL="postgres://littlelove:dev@localhost:${POSTGRES_PORT}/littlelove_test"; cargo test -p littlelove-api --test room_mutations )`
- [ ] **Step 3: Migration 0017**: leading `--` comment explaining why; `ALTER TABLE messages DROP CONSTRAINT messages_room_id_fkey, ADD CONSTRAINT messages_room_id_fkey FOREIGN KEY (room_id) REFERENCES rooms(id) ON DELETE CASCADE;` (confirm the real constraint name first with `\d messages`). Audit other room-keyed tables (`grep -rn room_id server/migrations`); any FK to `rooms` without `ON DELETE` gets the same treatment in this migration.
- [ ] **Step 4: `delete_room`** in `rooms.rs`: one `DELETE FROM rooms WHERE id = $1`, `rows_affected() > 0`. Fix `leave_room`'s doc so it no longer claims messages cascaded before 0017.
- [ ] **Step 5: Schema test** `migration_0017_schema.rs` (model: `migration_0011_schema.rs`): `messages_room_id_fk_cascades_on_delete` asserts `information_schema.referential_constraints.delete_rule = 'CASCADE'` for `messages_room_id_fkey`.
- [ ] **Step 6: Run both test files, expect PASS.**
- [ ] **Step 7: Commit** `feat(server): messages cascade with their room; delete_room`.

### Task 2: Wire frames and error codes (server)

**Files:**
- Modify: `server/src/wire.rs`

**Interfaces:**
- Produces: `RoomClientFrame::DeleteRoom { room_id: String }`; `RoomServerFrame::RoomDeleted { room_id: String, deleted_by: String }`; `RoomServerFrame::Error` gains `#[serde(default, skip_serializing_if = "Option::is_none")] room_id: Option<String>`; `error_codes::PARTNER_CHAT_LOCKED = "PartnerChatLocked"`, `error_codes::INTERNAL = "Internal"`, `error_codes::BAD_NAME = "BadName"`.

- [ ] **Step 1: Failing unit tests** in `wire.rs` `mod tests`: `parses_delete_room_frame`; `serializes_room_deleted_frame` (contains `"kind":"RoomDeleted"`, `"deleted_by":"court"`); `error_frame_omits_room_id_when_none` and `error_frame_carries_room_id` (`"room_id":"01J"`).
- [ ] **Step 2: Run, expect FAIL.** `cargo test -p littlelove-api --lib wire`
- [ ] **Step 3: Add the variants, field and constants.** Update the 4 existing `RoomServerFrame::Error { .. }` constructions with `room_id: None` (`send_error` included).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(wire): DeleteRoom/RoomDeleted frames, room_id on errors`.

### Task 3: `handle_delete_room` and the partner-chat guards

**Files:**
- Modify: `server/src/ws.rs`
- Create: `server/tests/delete_room_ws.rs`
- Modify: `.claude/rules/rust.md` (Known gaps: `DeleteRoom` is now rate-limited; `"Internal"`/`"BadName"` literals replaced in the handlers this touches)

**Interfaces:**
- Consumes: Task 1 `delete_room`; Task 2 frames/codes.
- Produces: `fn send_room_error(tx, code: &str, room_id: &str)`; `const DELETE_RL_WINDOW: Duration = 60 s`, `const DELETE_RL_MAX: usize = 5` (documented rationale: deletes are rare and fan out).

- [ ] **Step 1: Failing integration tests** in `delete_room_ws.rs` (`#[file_serial(db)]`, two sockets like `typing_ws.rs`, a channel created with `create_room_with_members(.., "Travel")` plus the unnamed partner room):
  - `delete_room_removes_channel_and_notifies_both_members`: court sends `DeleteRoom`; both sockets get `RoomDeleted { room_id, deleted_by: "court" }`; the room row is gone.
  - `delete_room_with_messages_succeeds`: a stored message in the channel; still both get `RoomDeleted`.
  - `delete_room_for_non_member_is_unknown_room`: a third account gets `Error { code: "UnknownRoom", room_id }`.
  - `delete_partner_chat_is_refused`: `Error { code: "PartnerChatLocked", room_id }`, room still exists.
  - `rename_partner_chat_is_refused` and `rename_channel_to_empty_is_refused` (`BadName`), `create_room_with_empty_name_is_refused` (`BadName`).
  - `delete_room_flood_is_rate_limited`: 6 deletes of nonexistent ids, the 6th reply is `RateLimited` with that `room_id`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** `handle_delete_room(&state, &me, &room_id, &tx)` per spec "Server" steps 2-5: `is_member` else `UNKNOWN_ROOM`; `room_detail` name empty → `PARTNER_CHAT_LOCKED`; collect `members_for_room`; `delete_room`; deliver `RoomDeleted` to every member. Every error from this handler goes through `send_room_error`. Dispatch arm with `delete_rl`. In `handle_rename_room`: trimmed empty name → `BAD_NAME`; current name empty → `PARTNER_CHAT_LOCKED` (send with `room_id`). In `handle_create_room`: trimmed empty name → `BAD_NAME` (pairing uses the invite path at `ws.rs:876`, unaffected). Use `error_codes::INTERNAL`/`BAD_NAME` in the handlers touched.
- [ ] **Step 4: Connect guard:** in `handle_socket`, when `list_rooms_for_account` fails, `warn!`, `state.routing.unregister(..)` and `return` (the socket closes; the app reconnects with backoff) instead of sending an empty `Rooms`. Test `rooms_list_failure_closes_instead_of_sending_empty` is optional if a DB failure can't be injected; if skipped, say so in the PR.
- [ ] **Step 5: Run the new file and `room_mutations`, `rooms_routing`, `create_room_reinvite`, expect PASS.**
- [ ] **Step 6: Full server gate** (`cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` against `littlelove_test`).
- [ ] **Step 7: Commit** `feat(server): DeleteRoom handler; lock the partner chat's name`.

### Task 4: Wire frames (app)

**Files:**
- Modify: `app/lib/wire/frames.dart`, `app/lib/wire/live_pairing_transport.dart`, `app/lib/conversation/room_message_router.dart`
- Test: `app/test/wire/frames_v0_3_test.dart`

**Interfaces:**
- Produces: `class DeleteRoomFrame { const DeleteRoomFrame({required String roomId}); Map<String, Object?> toJson(); }`; `class RoomDeletedFrame extends RoomServerFrame { roomId, deletedBy }`; `RoomErrorFrame` gains `final String? roomId` (parsed from `room_id`).

- [ ] **Step 1: Failing tests:** `DeleteRoomFrame serializes`; `RoomDeleted parses room_id and deleted_by`; `Error parses an optional room_id` (absent → null).
- [ ] **Step 2: Run, expect FAIL.** `flutter test test/wire/frames_v0_3_test.dart`
- [ ] **Step 3: Implement.** Add `RoomDeletedFrame()` to `live_pairing_transport`'s ignored set and an empty `case RoomDeletedFrame():` (comment: applied in Task 6) in the router so the exhaustive switches compile.
- [ ] **Step 4: Run, expect PASS; `flutter analyze`.**
- [ ] **Step 5: Commit** `feat(wire): DeleteRoom/RoomDeleted frames in the app`.

### Task 5: Local Hide + Purge

**Files:**
- Modify: `app/lib/conversation/message_db.dart`, `app/lib/inbox/inbox_state.dart`, `app/lib/inbox/read_state_provider.dart`, `app/lib/attachment/attachment_download.dart`
- Create: `app/lib/inbox/room_removal.dart`
- Test: `app/test/conversation/message_db_test.dart`, `app/test/inbox/room_removal_test.dart`; update the `MessageDb` fakes (`sign_out_test.dart`, `auth_gate_test.dart`)

**Interfaces:**
- Produces:
  - `MessageDb.roomIds() -> Future<Set<String>>` (distinct `room_id` across `messages`, `room_sync`, `drafts`).
  - `MessageDb.purgeRoom(String roomId) -> Future<List<AttachmentDescriptor>>`: returns the room's attachment descriptors, then deletes its `messages` rows (FTS trigger), `room_sync`, `drafts`, and `tombstones`/`pending_edits`/`deleted_for_me` rows whose target ids were in that room, in one transaction.
  - `InboxStateNotifier.removeRoom(String roomId)`.
  - `ReadStateNotifier.forget(String roomId)` (writes through like `markRead`).
  - `Future<void> evictCachedAttachment(AttachmentDescriptor d)` in `attachment_download.dart` (best-effort delete of the cache file).
  - `void hideRoom(Ref ref, String roomId)` and `Future<void> purgeRoomLocally(Ref ref, String roomId)` in `room_removal.dart`. Purge: `db.purgeRoom` + evict each descriptor; outbox rows with that `roomId` removed (`pending()` filter + `remove`); `readStateProvider.forget`; `ref.invalidate` of `messageStoreProvider(roomId)`, `roomHydratedProvider(roomId)`, `typingProvider(roomId)`; `roomKeyCacheProvider.invalidate(roomId)`; clear the profile avatar publish cache (`setAvatar(null, null)`) so the next connect re-uploads into the partner chat. Faults: `reportFault(e, st, context: 'room_purge')`.
- [ ] **Step 1: Failing DB tests:** `purgeRoom removes every trace of the room and nothing else` (two rooms seeded with messages, a draft, an HWM, a tombstone, a pending edit, a deleted-for-me id, an FTS-searchable body; after purge of room1: `messagesFor('room1')` empty, `search` finds only room2, `draftFor`/`highWaterMark` null for room1, room2 untouched); `purgeRoom returns the room's attachment descriptors`; `roomIds lists rooms with any local data`.
- [ ] **Step 2: Failing removal test** (`room_removal_test.dart`, `ProviderContainer` with ffi `MessageDb`, `MemoryOutboxStore`, hermetic read state): `purgeRoomLocally clears outbox rows, read state and the store for that room only`; `hideRoom drops the inbox row`.
- [ ] **Step 3: Run, expect FAIL.**
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run, expect PASS; analyze.**
- [ ] **Step 6: Commit** `feat(app): hide and purge a room locally`.

### Task 6: Apply `RoomDeleted`; guarded sweep; profile room pin

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`, `app/lib/profile/profile_service.dart`
- Create: `app/lib/inbox/room_deletion_events.dart`
- Test: `app/test/conversation/room_message_router_test.dart`, `app/test/profile/profile_service_test.dart` (create if absent)

**Interfaces:**
- Consumes: Task 4 frames; Task 5 `hideRoom`/`purgeRoomLocally`/`roomIds`.
- Produces: `class RoomDeletion { final String roomId; final String roomName; final String deletedBy; }`; `final roomDeletionsProvider = NotifierProvider<RoomDeletionsNotifier, RoomDeletion?>` whose `emit(RoomDeletion)` sets state (a new object each time so listeners fire).

- [ ] **Step 1: Failing router tests:**
  - `RoomDeleted hides and purges the room and emits a RoomDeletion` (room name captured before removal, `deletedBy` from the frame).
  - `a frame for a deleted room arriving after RoomDeleted is dropped` (Message, Read, Typing, RoomRenamed for that id: no inbox row, no store rows, no DB rows).
  - `a Rooms list missing a locally known room purges it` (partner room present).
  - `an empty Rooms list purges nothing`; `a Rooms list without the partner chat purges nothing`.
- [ ] **Step 2: Failing profile test:** `coupleRoomFor prefers the unnamed partner room over an older channel`; falls back to lowest id when no unnamed room.
- [ ] **Step 3: Run, expect FAIL.**
- [ ] **Step 4: Implement.** Router keeps `final Set<String> _deletedRooms`; `_onFrame` drops any room-scoped frame whose room id is in it, and `_subscribe`/`_upsertRoom` skip it. `RoomDeletedFrame`: look up the room (name), add to `_deletedRooms`, `hideRoom`, `await purgeRoomLocally`, `ref.read(roomDeletionsProvider.notifier).emit(...)`. Sweep after `setRooms`: skip when `mapped` is empty or has no `RoomShape.partner` room for me; else purge each `db.roomIds()` not in `mapped` (no event). After a purge that cleared the avatar cache, `unawaited(_republishMyProfile())`. If the call controller has an active or ringing call in the deleted room, end it through its existing hang-up path (test: `RoomDeleted ends a call in that room`). `coupleRoomFor`: prefer the room whose `name.isEmpty` with exactly one other member; else current behaviour.
- [ ] **Step 5: Run, expect PASS; analyze.**
- [ ] **Step 6: Commit** `feat(app): apply RoomDeleted, guarded reconnect sweep, pin profile room`.

### Task 7: Delete request, sheet, chat-info row, navigation and toasts

**Files:**
- Create: `app/lib/inbox/channel_deletion.dart`, `app/lib/conversation/delete_channel_sheet.dart`
- Modify: `app/lib/conversation/chat_info_page.dart`, `app/lib/conversation/conversation_page.dart`, `app/lib/screens/inbox/home_screen.dart`
- Test: `app/test/inbox/channel_deletion_test.dart`, `app/test/conversation/delete_channel_sheet_test.dart`, `app/test/conversation/chat_info_page_test.dart`, `app/test/screens/inbox/home_screen_test.dart`

**Interfaces:**
- Consumes: Task 4 frames; Task 6 `roomDeletionsProvider`.
- Produces:
  - `enum DeleteChannelOutcome { deleted, offline, failed }`
  - `bool channelNameMatches(String typed, String name)`
  - `Future<DeleteChannelOutcome> requestChannelDeletion({required LiveConnection? conn, required String roomId, Duration timeout = const Duration(seconds: 10)})`: null conn → `offline`; listen to `conn.incoming` **before** sending `DeleteRoomFrame`; `RoomDeletedFrame` with that id → `deleted`; `RoomErrorFrame` with that `roomId`: `UnknownRoom` → `deleted`, other → `failed`; errors without a matching `roomId` ignored; timeout → `failed`.
  - `Future<void> showDeleteChannelSheet(BuildContext context, {required Room room, required Future<DeleteChannelOutcome> Function() onDelete})`, keys `delete-channel-field`, `delete-channel-confirm`, `delete-channel-cancel`.
  - `ChatInfoPage`/`ChatInfoPage.route`/`ConversationPage` gain `final Future<DeleteChannelOutcome> Function()? onDeleteChannel` (null hides the row; row key `chat-info-delete-channel`).

- [ ] **Step 1: Failing unit tests** (`channel_deletion_test.dart`, fake `LiveConnection`): `channelNameMatches` cases (`'travel'`/`'Travel'` true, `' Travel '` true, `'Trave'` false, emoji name requires the emoji); outcomes for null conn, `RoomDeleted`, matching `UnknownRoom`, matching `RateLimited`, an unrelated error with another or no `roomId` followed by `RoomDeleted` (→ `deleted`), and timeout (`fakeAsync`).
- [ ] **Step 2: Failing widget tests:**
  - Sheet: confirm disabled until a match; tapping it fires a medium haptic and calls `onDelete`; `offline` → offline SnackBar and the sheet stays; `failed` → failure SnackBar and the sheet stays; Cancel pops.
  - Chat info: the row shows for a channel with `onDeleteChannel`, is absent for the partner chat and when null.
  - Home screen: a `RoomDeletion` for the open room pops to the inbox and toasts `Channel deleted` when `deletedBy` is me, `Kaitlyn deleted Travel` when it's the partner; a `RoomDeletion` for another room shows nothing and doesn't navigate.
- [ ] **Step 3: Run, expect FAIL.**
- [ ] **Step 4: Implement.** Sheet styling per spec "Confirmation sheet" (New channel sheet pattern; enabled button `warningTone` fill, label colour that clears 4.5:1, asserted in `palette_contrast_test.dart`; a spinner while waiting). Chat info: a caption-less `InfoSection` card after "THIS CHAT" with one row in `warningTone`, no chevron. Home screen: pass `onDeleteChannel` only for `RoomShape.chat` (`() => requestChannelDeletion(conn: ref.read(liveConnectionProvider).valueOrNull, roomId: room.roomId)`); track the open room id in `_openRoom`; `ref.listen(roomDeletionsProvider, ...)` → if it's the open room: `Navigator.popUntil(first)` then `showLoveToast` (copy per Global Constraints; partner name = display name else capitalized username, as `chat_info_page.dart` does).
- [ ] **Step 5: Run, expect PASS; analyze.**
- [ ] **Step 6: Commit** `feat(app): delete channel sheet, chat-info row and navigation`.

### Task 8: Gate, docs, PR

**Files:**
- Modify: `REVIEW.md` / `CLAUDE.md` / `.claude/rules/*.md` only if a statement became untrue.

- [ ] **Step 1:** Full app gate with the CI SDK: `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test`; full server gate (Task 3 Step 6). Revert SDK churn.
- [ ] **Step 2:** Docs drift check (e.g. `rust.md` Known gaps, `leave_room` comment done in Task 1).
- [ ] **Step 3:** Fresh whole-branch review against `REVIEW.md`; fix BLOCKER/MAJOR.
- [ ] **Step 4:** Push, open the PR (body: what, how, the release order from the spec "Rollout": app to both phones first, then server).
