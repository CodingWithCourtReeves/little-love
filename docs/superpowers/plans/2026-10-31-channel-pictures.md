# Channel Pictures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every channel's "#" with a picture (photo, symbol on a colour, or the channel's letter) that both partners can change, sent end-to-end encrypted as a new `channel_update` message kind, with chat lines for picture changes and renames.

**Architecture:** A new `lib/channel/` feature folder holds the picture model, the tile widget, the picker sheet, the sender service and the pending-action registry. The picture travels as an ordinary E2EE message through `buildSendFrame` + outbox. The router turns it into a timeline `Msg` carrying `channelUpdate`, persisted in `MessageDb`. The current picture is derived from the room's `MessageStore`. No server change.

**Tech Stack:** Flutter/Dart 3, Riverpod 2 (hand-written providers), sqflite/SQLCipher, `image_picker`, `image`, `flutter_svg` (already a dependency), Lucide SVG icons (ISC).

**Spec:** `docs/superpowers/specs/2026-10-31-channel-pictures-design.md` (read it with this plan). Mockups: https://claude.ai/artifact/8xMaweMhRxDQp3PBdzKVe3

## Global Constraints

- Run every Flutter/Dart command with the CI SDK, not PATH: `export PATH="$HOME/actions-runner/_work/_tool/flutter/stable-3.44.9-arm64/flutter/bin:$PATH"` (PATH Flutter 3.47 churns `pubspec.lock`, the iOS target and `analysis_options`). Revert any such churn before committing.
- All commands below run from `app/` in the worktree `/Users/courtreeves/projects/little-love/.claude/worktrees/channel-pictures`.
- Follow `.claude/rules/dart.md` and `REVIEW.md`: relative imports in `lib/`, `package:littlelove/...` in tests, no mockito, real crypto, condition-based waits (`test/support/widget_waits.dart`: `pumpUntilTrue`, `pumpUntilFound`), tests named as invariant sentences, `reportFault` contexts constant, no raw `Color(0x...)` outside `theme/`.
- User-facing copy has no em dashes.
- Wire names are fixed: kind `channel_update`; picture `type` values `photo`, `symbol`, `none`; symbols `heart house plane paw utensils music film star gift sun leaf moon`; colours `rose clay sand sage sky lavender`.
- Channel tiles are rounded squares, radius = `size * 14 / 52`. The partner chat stays a circle everywhere.
- Photo: centre-cropped square, 512x512 JPEG quality 88; thumbnail `maxEdge: 128, maxThumbBytes: 12 * 1024`; uploaded to the **channel's own** roomId.
- A `channel_update` never bumps unread, never pops the in-app banner, never chimes, is never FTS-indexed (row `body` is `''`), and can't be replied to or reacted to.
- One commit per task. Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GLAwZP5xSYScWybVeZstSh
  ```

## Review Focus

1. **The partner's phone updates.** A change made on one phone must show on the other after a live receive, after a reconnect replay and after a reinstall (DB empty, full replay). Owned by Task 3 (router replay test) and Task 4 (provider after re-hydrate).
2. **Two changes close together.** Both phones must settle on the same picture: the one with the later server `ts`, tie broken by `id`. Owned by Task 4 (`latest wins by ts then id even when arrival order differs`).
3. **The photo can't be downloaded yet** (offline, or a slow blob). The tile must show the 128px thumbnail, never a blank square or a spinner. Owned by Task 5 (`photo picture without a downloaded file shows the inline thumbnail`).
4. **Names with no letter** ("🏖️ beach", "123", ""). The letter tile must not crash or show a broken glyph: take the first grapheme of the display name, uppercased; if empty, show the symbol-less tint only. Owned by Task 5 (`letter tile uses the first grapheme and survives an empty name`).
5. **The user cancels the iOS photo picker, or the photo is undecodable (HEIC that `image` can't read).** Nothing is sent, the sheet stays open, and a SnackBar says "Couldn't use that photo." Owned by Task 8.

---

## File Structure

New, in `app/lib/channel/`:
- `channel_picture.dart`: `ChannelSymbol`, `ChannelColor`, sealed `ChannelPicture` (+ JSON), `ChannelPictureChoice` (what the sheet returns), `channelColorFor(seed)`.
- `channel_line.dart`: `channelLineText(...)`, the copy for chat lines and previews.
- `channel_picture_provider.dart`: `currentChannelPictureProvider`, `channelPhotoFileProvider`.
- `channel_tile.dart`: `ChannelPictureView` (pure) and `ChannelTile` (reads providers).
- `channel_picture_sheet.dart`: `showChannelPictureSheet(...)`.
- `channel_update_sender.dart`: `ChannelUpdateSender` + provider.
- `pending_channel_actions.dart`: `PendingChannelActions` + provider.

New elsewhere:
- `app/lib/attachment/square_image.dart`: `squareJpeg`, `uploadSquareImage` (moved out of profile code).
- `app/assets/channel_symbols/*.svg` (12 Lucide icons) and `app/assets/channel_symbols/LICENSE`.

Modified: `conversation/message_content.dart`, `wire/message.dart`, `conversation/message_db.dart`, `conversation/message_store.dart` (`_withEdit` copy), `conversation/room_message_router.dart`, `outbox/outbox_rehydrate.dart`, `inbox/read_state_provider.dart`, `inbox/room_preview.dart`, `conversation/conversation_page.dart`, `conversation/chat_info_page.dart`, `conversation/shared_media_page.dart`, `screens/inbox/home_screen.dart`, `screens/create_chat/create_channel_sheet.dart`, `screens/profile/profile_screen.dart`, `profile/profile_service.dart`, `theme/app_palette.dart`, `identity/sign_out.dart`, `main.dart`, `pubspec.yaml`.

---

### Task 1: Picture model, `channel_update` kind, forward-compatible decode

**Files:**
- Create: `app/lib/channel/channel_picture.dart`, `app/lib/channel/channel_line.dart`
- Modify: `app/lib/conversation/message_content.dart`
- Test: `app/test/conversation/message_content_test.dart`, `app/test/channel/channel_picture_test.dart`

**Interfaces:**
- Produces:
  - `enum ChannelSymbol { heart, house, plane, paw, utensils, music, film, star, gift, sun, leaf, moon }` and `enum ChannelColor { rose, clay, sand, sage, sky, lavender }` (wire name = `.name`).
  - `sealed class ChannelPicture { Map<String, Object?> toJson(); static ChannelPicture fromJson(Map<String, Object?> j); }` with `PhotoPicture(AttachmentDescriptor descriptor)`, `SymbolPicture(ChannelSymbol symbol, ChannelColor color)`, `NoPicture()`, `UnknownPicture()` (unknown `type`, symbol or colour; renders as the letter; never encoded by this build, `toJson` throws `StateError`).
  - `sealed class ChannelPictureChoice` with `ChoosePhoto(Uint8List squaredJpeg)`, `ChooseSymbol(ChannelSymbol symbol, ChannelColor color)`, `ChooseNone()`.
  - `ChannelColor channelColorFor(String seed)`: `h = (h * 31 + c) & 0x7fffffff` over `seed.codeUnits`, index `h % 6` (same hash as `Avatar._color`).
  - `class ChannelUpdateContent extends MessageContent { const ChannelUpdateContent({this.picture, this.name}); final ChannelPicture? picture; final String? name; }` encoding `{"v":1,"kind":"channel_update","picture":{...}}` or `{"v":1,"kind":"channel_update","name":"..."}`.
  - `class UnsupportedContent extends MessageContent { const UnsupportedContent(this.raw); final String raw; }` (`encode()` returns `raw`).
  - `String channelLineText(ChannelUpdateContent c, {required String who})`: `'$who changed the channel picture'` (photo, symbol, unknown), `'$who removed the channel picture'` (`NoPicture`), `'$who renamed the channel to ${c.name}'` (name). `who` is `'You'` or the partner's name, supplied by the caller.

- [ ] **Step 1: Write the failing tests**

In `message_content_test.dart`:
- `'channel_update round-trips a photo, a symbol, none and a name'`: encode then `MessageContent.decode` each; expect the same variant and fields (`SymbolPicture(ChannelSymbol.plane, ChannelColor.sky)`, a `PhotoPicture` whose `descriptor.blobKey` matches, `NoPicture`, `name == 'Trips'`).
- `'an unknown symbol or colour decodes to UnknownPicture, not a throw'`: decode `{"v":1,"kind":"channel_update","picture":{"type":"symbol","symbol":"rocket","color":"sky"}}` → `UnknownPicture`; same for `"color":"teal"` and `"type":"gif"`.
- `'an unknown v1 kind decodes to UnsupportedContent carrying the raw plaintext'`: decode `{"v":1,"kind":"poll","q":"x"}` → `UnsupportedContent` with `raw` equal to the input.
- `'non-JSON and non-v1 plaintext still decode as text'`: `'hello'` → `TextContent('hello')`; `{"v":2,"kind":"text","text":"x"}` → `TextContent` of the raw string.

In `test/channel/channel_picture_test.dart`:
- `'channelColorFor is stable for a seed and spreads across all six colours'`: same seed twice gives the same colour; the seeds `'r1'..'r60'` hit all 6 values.
- `'channelLineText words each change'`: `'Kaitlyn changed the channel picture'`, `'You removed the channel picture'`, `'Kaitlyn renamed the channel to Trips'`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/conversation/message_content_test.dart test/channel/channel_picture_test.dart`
Expected: FAIL (types not defined).

- [ ] **Step 3: Implement**

Add the types above. In `MessageContent.decode`, add `case 'channel_update':` and change the fall-through so that a map with `v == 1` and an unrecognised `kind` returns `UnsupportedContent(raw)`; non-map / non-v1 still returns `TextContent(raw)`. Wrap `ChannelPicture.fromJson` so a missing or mistyped field yields `UnknownPicture` (catch `FormatException` and `TypeError`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/conversation/message_content_test.dart test/channel/channel_picture_test.dart`
Expected: PASS. The analyzer will now flag the two exhaustive switches (router, outbox rehydrate); Task 3 fixes them. To keep this commit green, add placeholder cases there that do what Task 3 specifies for `UnsupportedContent` (drop) and `ChannelUpdateContent` (drop) with a comment, then run `flutter analyze` (expected: no issues).

- [ ] **Step 5: Commit** (`feat(channel): channel_update message kind and forward-compatible decode`)

---

### Task 2: `Msg` fields and `MessageDb` schema v6

**Files:**
- Modify: `app/lib/wire/message.dart`, `app/lib/conversation/message_db.dart`, `app/lib/conversation/message_store.dart` (`_withEdit`)
- Test: `app/test/conversation/message_db_test.dart`

**Interfaces:**
- Consumes: `ChannelUpdateContent`, `UnsupportedContent` (Task 1).
- Produces:
  - `Msg.channelUpdate` (`ChannelUpdateContent?`), `Msg.unsupportedBody` (`String?`), both in the constructor and `copyWith`; `bool get isTimelineEvent => callOutcome != null || channelUpdate != null;` `bool get isHidden => unsupportedBody != null;`
  - `MessageDb.schemaVersion = 6`; new nullable columns `channel_update TEXT` (the content's `encode()`) and `raw_body TEXT`; `_toRow`/`_fromRow` round-trip both (`_fromRow` decodes `channel_update` via `MessageContent.decode` and keeps it only if it is a `ChannelUpdateContent`).

- [ ] **Step 1: Write the failing tests** in `message_db_test.dart`:
  - `'a channel_update row round-trips through the cache'`: upsert a `Msg(body: '', channelUpdate: ChannelUpdateContent(picture: SymbolPicture(...)))`, read `messagesFor`, expect the same picture.
  - `'a hidden row keeps its raw plaintext and is not searchable'`: upsert a `Msg(body: '', unsupportedBody: '{"v":1,"kind":"poll"}')`; `messagesFor` returns it with `unsupportedBody` set; `search('poll', roomId: …)` returns nothing.
  - `'upgrading a v5 cache adds the new columns and keeps old rows'`: open with v5 `onCreate`, insert a row, run `onUpgrade(db, 5, 6)`, read it back with null `channelUpdate`.
- [ ] **Step 2: Run** `flutter test test/conversation/message_db_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the fields, getters, `copyWith`, `_withEdit` passthrough, `onCreate` columns, `if (oldV < 6)` with two `ALTER TABLE messages ADD COLUMN ...` statements.
- [ ] **Step 4: Run** the same command. Expected: PASS. Then `flutter test test/conversation` (expected: PASS).
- [ ] **Step 5: Commit** (`feat(channel): persist channel updates and hidden rows in the message cache`)

---

### Task 3: Router ingest, hydrate re-decode, outbox rehydrate

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`, `app/lib/outbox/outbox_rehydrate.dart`
- Test: `app/test/conversation/room_message_router_test.dart`, `app/test/outbox/outbox_rehydrate_test.dart`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: router behaviour only. Refactor `_ingestMessage` so the post-decrypt part is `Future<void> _applyContent(MessageFrame f, Room room, MessageContent content)`, reused by hydrate.

Behaviour:
- `ChannelUpdateContent` in a room whose `shape(self) == RoomShape.chat`: becomes a `Msg(body: '', channelUpdate: content, …)` and goes through the same `reconcile`/`add` + `db.upsert` + outbox-remove path as other timeline rows, but skips the chime, banner and `markRoomRead` live branch (keep `_scheduleMarkRead` for replays). In the partner room it is dropped (outbox row still removed on echo).
- `UnsupportedContent`: `db.upsert(Msg(body: '', unsupportedBody: raw, …))` only; never `store.add`; outbox row removed on echo; no feedback.
- `_hydrate`: rows with `isHidden` are not passed to `setAll`; each is re-decoded with `MessageContent.decode(unsupportedBody)`; if the result is no longer `UnsupportedContent`, run it through `_applyContent` as a replay (construct the frame fields from the row: id, from, ts, `replayed: true`).
- `outbox_rehydrate.dart`: `ChannelUpdateContent` rehydrates an optimistic row with `body: ''`, `channelUpdate: content`, `sendStatus: sending`; `UnsupportedContent` is skipped.

- [ ] **Step 1: Write the failing tests** (router test file already has fakes and `pumpUntil`):
  - `'a channel_update from the partner adds a timeline row without unread, chime or banner'`.
  - `'a channel_update in the partner chat is ignored'`.
  - `'an unknown kind is kept hidden in the cache and never reaches the timeline'`.
  - `'a hidden row this build understands is re-applied on hydrate'`: seed the DB with a hidden row whose raw body is a valid `channel_update`, hydrate, expect the row in `MessageStore` with `channelUpdate` set.
  - `'my own channel_update echo reconciles the optimistic row and clears the outbox'`.
  - In `outbox_rehydrate_test.dart`: `'a pending channel_update rehydrates as a sending channel row'`.
- [ ] **Step 2: Run** `flutter test test/conversation/room_message_router_test.dart test/outbox/outbox_rehydrate_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** as described.
- [ ] **Step 4: Run** the same tests (PASS), then `flutter analyze` (no issues).
- [ ] **Step 5: Commit** (`feat(channel): route channel updates and keep unknown kinds hidden`)

---

### Task 4: Current-picture provider

**Files:**
- Create: `app/lib/channel/channel_picture_provider.dart`
- Test: `app/test/channel/channel_picture_provider_test.dart`

**Interfaces:**
- Consumes: `messageStoreProvider`, `Msg.channelUpdate`.
- Produces:
  - `final currentChannelPictureProvider = Provider.family<ChannelPicture?, String>(…)` keyed by roomId: among rows with `channelUpdate?.picture != null` and `sendStatus != SendStatus.failed`, the max by `ts`, then `id`. Null when none or when the latest is `NoPicture`.
  - `final channelPhotoFileProvider = FutureProvider.family<File?, String>(…)` keyed by roomId: if the current picture is a `PhotoPicture`, `fetchAndDecrypt(conn: <live connection>, descriptor: …)`; null if no connection or not a photo. Errors are caught, reported as `reportFault(e, st, context: 'channel_picture_fetch')`, and yield null.

- [ ] **Step 1: Write the failing tests**:
  - `'no channel updates means no picture'`.
  - `'latest wins by ts then id even when arrival order differs'`: add B (ts 2) then A (ts 1) → B; two rows with equal ts → larger id.
  - `'a failed optimistic change does not replace the current picture'`.
  - `'removing the picture returns null'`.
  - `'the picture survives a hydrate from the cache'` (`setAll` with DB-built rows).
- [ ] **Step 2: Run** `flutter test test/channel/channel_picture_provider_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** (`feat(channel): derive the current channel picture`)

---

### Task 5: Palette swatches, symbol assets and the tile widget

**Files:**
- Create: `app/lib/channel/channel_tile.dart`, `app/assets/channel_symbols/{heart,house,plane,paw,utensils,music,film,star,gift,sun,leaf,moon}.svg`, `app/assets/channel_symbols/LICENSE`
- Modify: `app/lib/theme/app_palette.dart`, `app/pubspec.yaml` (assets), `app/lib/main.dart` (licence)
- Test: `app/test/channel/channel_tile_test.dart`, `app/test/theme/palette_contrast_test.dart`

**Interfaces:**
- Consumes: Tasks 1 and 4.
- Produces:
  - In `app_palette.dart`: `@immutable class ChannelSwatch { const ChannelSwatch(this.tint, this.ink); final Color tint; final Color ink; }` and `AppPalette.channelSwatches` (`List<ChannelSwatch>`, length 6, indexed by `ChannelColor.index`), wired through constructor, `copyWith` and `lerp` (lerp each pair). Values from the spec table (light: `E8C8D2/7E3753, F0D3C7/8A4630, EEE0CB/7A5A2E, D3E3D7/3F6A4D, D2E0EA/3A5F7A, DED5EA/5B4A7A`; dark: `5E2C49/F2CFDD, 5A3326/F5D6CA, 4E3F28/F1E2C9, 2F4A38/CFE6D5, 26394A/D3E3F0, 3E3354/E2D8F0`).
  - `class ChannelPictureView extends StatelessWidget { const ChannelPictureView({super.key, required this.name, required this.colorSeed, this.picture, this.photo, this.size = 52}); }`: `photo != null` → cover-fit image; else `SymbolPicture` → its swatch tint with the SVG at `size / 2`, tinted with the swatch ink via `ColorFilter.mode(ink, BlendMode.srcIn)`; else the letter (first grapheme of `name` via `characters`, uppercased, `size * 22 / 52` w600) in `channelColorFor(colorSeed)` ink on its tint. Clip radius `size * 14 / 52`. Key `Key('channel-picture-$colorSeed')`. Semantics label `'$name channel picture'`.
  - `class ChannelTile extends ConsumerWidget { const ChannelTile({super.key, required this.room, required this.selfUsername, this.size = 52}); }`: reads `currentChannelPictureProvider(room.roomId)` and, for photos, `channelPhotoFileProvider(room.roomId)`; passes `FileImage(file)` when downloaded, else `MemoryImage(base64Decode(descriptor.thumbB64))`; `colorSeed: room.roomId`; `name: room.displayName(selfUsername)`. Image decode bounded with `ResizeImage` to `size * devicePixelRatio`.
  - Assets come from `lucide-static@0.469.0` (`https://unpkg.com/lucide-static@0.469.0/icons/<name>.svg`): heart, house, send (saved as `plane.svg`), paw-print (as `paw.svg`), utensils, music, film, star, gift, sun, leaf, moon. Copy the package `LICENSE` beside them and register it with `LicenseRegistry.addLicense` in `main.dart` under the package name `lucide`.

- [ ] **Step 1: Write the failing tests**:
  - `channel_tile_test.dart`: `'symbol picture draws the symbol on its swatch'` (finds an `SvgPicture` and a `DecoratedBox`/`Container` with the swatch tint); `'photo picture without a downloaded file shows the inline thumbnail'` (a `MemoryImage` is in the tree); `'letter tile uses the first grapheme and survives an empty name'` (`'🏖️ beach'` → `'🏖️'`, `'trips'` → `'T'`, `''` → no `Text`, no throw); `'letter colour is stable across a rename'` (same roomId, two names → same tint); `'tiles are rounded squares, not circles'` (`ClipRRect` radius `14` at size 52).
  - `palette_contrast_test.dart`: `'channel swatch ink clears 4.5:1 on its tint in light and dark'` for all 12 pairs.
- [ ] **Step 2: Run** `flutter test test/channel/channel_tile_test.dart test/theme/palette_contrast_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement**; adjust any shade that fails contrast, keeping its hue.
- [ ] **Step 4: Run** again (PASS) and `flutter test test/theme` (PASS).
- [ ] **Step 5: Commit** (`feat(channel): channel tile, symbol assets and palette swatches`)

---

### Task 6: Channel lines in the timeline, previews and unread

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`, `app/lib/inbox/room_preview.dart`, `app/lib/inbox/read_state_provider.dart`
- Create: `app/lib/channel/channel_line_view.dart`
- Test: `app/test/conversation/conversation_page_runs_test.dart`, `app/test/inbox/room_preview_test.dart`, `app/test/inbox/read_state_provider_test.dart`

**Interfaces:**
- Consumes: `Msg.isTimelineEvent`, `Msg.channelUpdate`, `channelLineText`.
- Produces:
  - `class ChannelLineView extends StatelessWidget { const ChannelLineView({super.key, required this.text, this.failed = false, this.onRetry}); }`: `ChatSeparator` styling (bgSurface scrim at `ChatSeparator.scrimAlpha`, `separatorText`, 12pt w500), centred. When `failed`, appends `' Not sent. Tap to retry.'` in `warningTone` and the whole line is a 44pt-tall tap target calling `onRetry`. Key `Key('channel-line-${m.clientMsgId ?? m.id}')` (set by the caller).
  - `ConversationPage`: in `_itemize`, a row with `channelUpdate != null` becomes a new `_ChannelLineItem` (no bubble, no long-press menu; its time is covered by the day/gap separators, a deliberate simplification of the spec's "time on long-press"); bubble runs break around it (use `isTimelineEvent` in `breaksBefore`). Replace the other `callOutcome` guards with `isTimelineEvent`: `_canReply` (:678), the :1353 guard, `_isJumboLoveTap` (:2088). `who` = `'You'` for `selfUsername`, else the partner's profile display name, else the capitalised username.
  - `room_preview.dart` `_describe`: a `channelUpdate` row previews `channelLineText(...)` in `PreviewTone.placeholder`. `roomPreviewFor` gains a `String Function(String username)? nameFor` parameter, and `roomPreviewProvider` (:183) supplies it by watching `profileStoreProvider` (display name, else capitalised username). Hidden rows never appear (they're not in the store).
  - `read_state_provider.dart:86`: skip `m.isTimelineEvent`.

- [ ] **Step 1: Write the failing tests**:
  - `'a channel line breaks bubble runs and has no reply or react actions'` (long-press on the line shows no menu).
  - `'a failed channel line offers tap to retry'` (tap calls `onRetry` with the clientMsgId).
  - `'the home preview shows the channel line in the placeholder tone'`.
  - `'channel updates do not count as unread'`.
- [ ] **Step 2: Run** `flutter test test/conversation/conversation_page_runs_test.dart test/inbox/room_preview_test.dart test/inbox/read_state_provider_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again (PASS), then `flutter test test/conversation test/inbox` (PASS).
- [ ] **Step 5: Commit** (`feat(channel): show channel changes as chat lines`)

---

### Task 7: Square-image upload helper and the sender

**Files:**
- Create: `app/lib/attachment/square_image.dart`, `app/lib/channel/channel_update_sender.dart`
- Modify: `app/lib/screens/profile/profile_screen.dart` (use `squareJpeg`), `app/lib/profile/profile_service.dart` (use `uploadSquareImage`)
- Test: `app/test/attachment/square_image_test.dart`, `app/test/channel/channel_update_sender_test.dart`

**Interfaces:**
- Produces:
  - `Uint8List squareJpeg(Uint8List bytes, {int size = 512})`: moved verbatim from `_squareJpeg` (throws `FormatException('undecodable image')`).
  - `Future<AttachmentDescriptor> uploadSquareImage({required LiveConnection conn, required String roomId, required Uint8List jpeg, required String filename})`: `encryptFileBytes` → `uploadCiphertext(roomId:)` → `buildImageThumbnail(maxEdge: 128, maxThumbBytes: 12 * 1024)` → descriptor with `mime: 'image/jpeg'`. `ensureAvatarUploaded` calls it with `filename: 'avatar.jpg'` (behaviour unchanged).
  - `class ChannelUpdateSender { ChannelUpdateSender(this._ref); Future<bool> applyChoice({required Room room, required String selfUsername, required ChannelPictureChoice choice}); Future<bool> sendRenameLine({required Room room, required String selfUsername, required String name}); }` and `final channelUpdateSenderProvider = Provider<ChannelUpdateSender>(ChannelUpdateSender.new);`
    - `applyChoice`: `ChoosePhoto` → `uploadSquareImage(roomId: room.roomId, filename: 'channel.jpg')` → `PhotoPicture`; `ChooseSymbol` → `SymbolPicture`; `ChooseNone` → `NoPicture`. Then the shared send.
    - Shared send mirrors `_sendEncrypted` in `home_screen.dart`: optimistic `Msg(id: clientMsgId, body: '', channelUpdate: …, sendStatus: SendStatus.sending)` via `outboxIdGenProvider`; `buildSendFrame`; `outboxStore.enqueue`; `outboxDrain.kick()` (kick failure → `updateStatus(failed)`, still returns true). Any pre-enqueue error removes the optimistic row, calls `reportFault(e, st, context: 'channel_update_send')` (`'channel_picture_upload'` for upload errors) and returns false. No chime.
- Consumes: Task 1 types, `buildSendFrame`, `outboxStoreProvider`, `outboxDrainProvider`, `liveConnectionProvider`, `currentIdentityProvider`, `roomKeyCacheProvider`.

- [ ] **Step 1: Write the failing tests**:
  - `square_image_test.dart`: `'squareJpeg centre-crops to a 512 square'` (a 800x400 PNG → decoded 512x512); `'squareJpeg rejects undecodable bytes with a FormatException'`.
  - `channel_update_sender_test.dart` (memory outbox store from `test/outbox/memory_outbox_store.dart`, real identities): `'choosing a symbol adds a sending channel row and enqueues one ciphertext per member'`; `'a failure before enqueue removes the optimistic row and returns false'`; `'sendRenameLine enqueues a name-only channel_update'`.
- [ ] **Step 2: Run** `flutter test test/attachment/square_image_test.dart test/channel/channel_update_sender_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement**; update the profile call sites.
- [ ] **Step 4: Run** again (PASS) and `flutter test test/profile test/screens/profile` (PASS: avatar behaviour unchanged).
- [ ] **Step 5: Commit** (`feat(channel): send channel updates and share the square-photo upload`)

---

### Task 8: The picker sheet and "pick from this chat's photos"

**Files:**
- Create: `app/lib/channel/channel_picture_sheet.dart`
- Modify: `app/lib/conversation/shared_media_page.dart`
- Test: `app/test/channel/channel_picture_sheet_test.dart`, `app/test/conversation/shared_media_page_test.dart` (new file)

**Interfaces:**
- Produces:
  - `Future<ChannelPictureChoice?> showChannelPictureSheet(BuildContext context, {required String name, required String colorSeed, ChannelPicture? current, ImageProvider? currentPhoto, Room? room})`. Returns null on Cancel or dismiss. `room == null` (create sheet) hides "Pick from this chat's photos".
  - Layout per spec/mockup: Cancel / "Channel picture" / Done (keys `channel-picture-cancel`, `channel-picture-done`); 96pt `ChannelPictureView` preview with the name under it; segmented Photo | Symbol (keys `channel-picture-tab-photo`, `channel-picture-tab-symbol`; opens on Symbol unless `current` is a photo); Photo rows `channel-picture-library`, `channel-picture-camera`, `channel-picture-from-chat`; Symbol grid keys `channel-symbol-<name>` (52pt cells, selected ring `accentUser` 2px), swatches `channel-color-<name>` (48pt); `channel-picture-remove` ("Remove picture", `warningTone`) only when `current` is not null. Default selection: `current` symbol/colour, else `ChannelSymbol.heart` + `channelColorFor(colorSeed)`.
  - Picking a photo (`ImagePicker().pickImage(source: …, imageQuality: 100)`) or a chat photo runs `squareJpeg` off the UI thread (`compute`), previews it, and Done returns `ChoosePhoto`. Cancelled picker → nothing changes. Undecodable → SnackBar "Couldn't use that photo." and nothing changes.
  - `SharedMediaPage.pickPhotoRoute({required Room room}) → Route<AttachmentDescriptor>`: the Photos tab only, images only (no videos), tap pops the descriptor. The sheet then `fetchAndDecrypt`s it and squares the bytes.

- [ ] **Step 1: Write the failing tests** (`ImagePicker` via `setMockMethodCallHandler` on `plugins.flutter.io/image_picker`):
  - `'Done returns the chosen symbol and colour'`.
  - `'Cancel returns null'`.
  - `'Remove is shown only when a picture is set and returns ChooseNone'`.
  - `'a cancelled photo picker leaves the sheet open and unchanged'`.
  - `'an undecodable photo shows a SnackBar and sends nothing'`.
  - `'the create-sheet variant hides pick from this chat'`.
  - `'every control is at least 44 points tall'`.
  - `shared_media_page_test.dart`: `'pick mode shows photos only and pops the tapped descriptor'`.
- [ ] **Step 2: Run** `flutter test test/channel/channel_picture_sheet_test.dart test/conversation/shared_media_page_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** (`feat(channel): channel picture sheet`)

---

### Task 9: Tiles on the home list, chat info and the chat header

**Files:**
- Modify: `app/lib/screens/inbox/home_screen.dart`, `app/lib/conversation/chat_info_page.dart`, `app/lib/conversation/conversation_page.dart`
- Test: `app/test/screens/inbox/home_screen_test.dart`, `app/test/conversation/chat_info_page_test.dart`, `app/test/conversation/conversation_header_test.dart`

**Interfaces:**
- Consumes: `ChannelTile`, `showChannelPictureSheet`, `channelUpdateSenderProvider`.
- Produces:
  - `home_screen.dart`: channel rows lead with `ChannelTile(room: r, selfUsername: _me)`; `_ChannelTile` keeps only the "+" variant (rename it `_NewChannelTile`, key `new-channel-tile` unchanged).
  - `ChatInfoPage` gains `final Future<void> Function(ChannelPictureChoice choice)? onChannelPicture;` (null hides both entry points; null for the partner chat). Channel header: `ChannelTile(size: 96)` in the existing 4px `infoCardColor` ring (radius 30 outer), plus a 34pt `accentUser` camera badge, the whole thing a button keyed `chat-info-channel-picture` with semantics "Change channel picture". New `InfoRow` in THIS CHAT keyed `chat-info-channel-picture-row`, label "Channel picture", trailing 28pt `ChannelTile`. Both open `showChannelPictureSheet(room: room, …)` and pass a non-null result to `onChannelPicture`. Encryption note for channels: `'Messages, calls, media and this channel\'s picture are end-to-end encrypted. Only $who can see them.'`
  - `ConversationPage` gains the same optional `onChannelPicture` and forwards it to `ChatInfoPage.route`. For a channel, the header action `room-header-avatar` shows `ChannelTile(size: 34)`; the partner chat keeps the `Avatar`.
  - `home_screen.dart` `_openRoom` passes `onChannelPicture: shape == partner ? null : (c) => _applyChannelPicture(room, c)`, which calls `applyChoice` and on `false` shows SnackBar "Couldn't save the channel picture."

- [ ] **Step 1: Write the failing tests**:
  - `home_screen_test.dart`: `'channel rows show their picture tile and the partner row stays a circle'`.
  - `chat_info_page_test.dart`: `'tapping the channel picture opens the sheet and Done calls onChannelPicture'`; `'the channel picture row opens the same sheet'`; `'the partner chat has no channel picture controls'`; `'the encryption note mentions the channel picture'`.
  - `conversation_header_test.dart`: `'a channel header shows the channel tile, the partner chat shows the avatar'`.
- [ ] **Step 2: Run** `flutter test test/screens/inbox/home_screen_test.dart test/conversation/chat_info_page_test.dart test/conversation/conversation_header_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again (PASS), then `flutter test` (PASS).
- [ ] **Step 5: Commit** (`feat(channel): show and change channel pictures from the list, info and header`)

---

### Task 10: Rename lines and the new-channel picture

**Files:**
- Create: `app/lib/channel/pending_channel_actions.dart`
- Modify: `app/lib/conversation/room_message_router.dart` (RoomCreated, RoomRenamed), `app/lib/screens/inbox/home_screen.dart` (`onRename`), `app/lib/conversation/chat_info_page.dart` (`_rename`), `app/lib/screens/create_chat/create_channel_sheet.dart`
- Test: `app/test/channel/pending_channel_actions_test.dart`, `app/test/conversation/room_message_router_test.dart`, `app/test/conversation/chat_info_page_test.dart`, `app/test/screens/create_channel_sheet_test.dart`

**Interfaces:**
- Produces:
  - `class PendingChannelActions { void expectCreated(String name, ChannelPictureChoice choice); ChannelPictureChoice? takeCreated(String name); void expectRename(String roomId, String name); bool takeRename(String roomId, String name); }` with `final pendingChannelActionsProvider = Provider<PendingChannelActions>((ref) => PendingChannelActions());`. `take*` consume the entry.
  - Router: `RoomCreatedFrame` → after `_subscribe`, if `takeCreated(name)` returns a choice, `unawaited(sender.applyChoice(...))` (it catches internally; a `false` is already reported). `RoomRenamedFrame` → after `renameRoom`, if `takeRename(roomId, name)`, `unawaited(sender.sendRenameLine(...))`. Self username from `accountProvider` as `_republishMyProfile` does.
  - `home_screen.dart` `onRename`: call `expectRename(room.roomId, newName)` before sending `RenameRoomFrame`.
  - `chat_info_page.dart` `_rename`: Save disabled while the trimmed text is empty (`ValueListenableBuilder` on the controller).
  - `create_channel_sheet.dart`: replace the `'#'` with a 44pt button (key `channel-name-picture`) showing `ChannelPictureView(name: _formatted, colorSeed: _formatted, size: 44, …)` or, with an empty name, a camera glyph on `bgSurfaceAlt`. The letter in this sheet is drawn in `accentUser` on `bgSurfaceAlt` (neutral) so it doesn't change colour once the room gets its id. Tapping opens `showChannelPictureSheet(room: null, …)`; the choice is kept in state and previewed. On create: `expectCreated(name, choice)` (when a choice is set) before sending `CreateRoomFrame`.

- [ ] **Step 1: Write the failing tests**:
  - `pending_channel_actions_test.dart`: `'take returns a pending entry once and then null'`.
  - Router: `'a confirmed rename I asked for sends one rename line'`; `'a rename from the partner sends no line from me'`; `'a created room with a pending picture sends it once'`.
  - `chat_info_page_test.dart`: `'rename Save is disabled for an empty name'`.
  - `create_channel_sheet_test.dart`: `'picking a picture in the new-channel sheet registers it for the created room'`; `'skipping the picture registers nothing'`.
- [ ] **Step 2: Run** `flutter test test/channel/pending_channel_actions_test.dart test/conversation/room_message_router_test.dart test/conversation/chat_info_page_test.dart test/screens/create_channel_sheet_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** (`feat(channel): rename lines and pick a picture when creating a channel`)

---

### Task 11: Sign-out wipe

**Files:**
- Modify: `app/lib/identity/sign_out.dart`
- Test: `app/test/identity/sign_out_test.dart`

**Interfaces:**
- Produces: sign-out awaits deletion of `<getApplicationSupportDirectory()>/attachments/` (recursive; missing folder is fine; errors caught with a comment, best-effort like the other steps) and invalidates `pendingChannelActionsProvider`, `currentChannelPictureProvider` and `channelPhotoFileProvider`. Use a `path_provider` mock in the test (`setMockMethodCallHandler` on `plugins.flutter.io/path_provider`) pointing at a temp dir.

- [ ] **Step 1: Write the failing test** `'sign-out deletes downloaded media, including channel pictures'`.
- [ ] **Step 2: Run** `flutter test test/identity/sign_out_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** again. Expected: PASS.
- [ ] **Step 5: Commit** (`fix(identity): sign-out deletes downloaded media`)

---

### Task 12: Full gate and device check

- [ ] **Step 1:** From `app/`: `dart format --output=none --set-exit-if-changed .` (exit 0), `flutter analyze` (no issues), `flutter test` (all pass). Check each command's own exit code.
- [ ] **Step 2:** `(cd ios && pod install) && flutter build ios --simulator --no-codesign` (succeeds). Revert any `pubspec.lock` / `Podfile` / `project.pbxproj` churn that isn't intended.
- [ ] **Step 3:** Update `REVIEW.md` or `.claude/rules/dart.md` if anything they say became untrue (for example, the dart.md line listing non-timeline kinds should mention `channel_update` and `Msg.isTimelineEvent`). Commit if changed.
- [ ] **Step 4:** Release install with `./scripts/ios-deploy.sh` on Court's iPhone 17 Pro Max (`0DC6E4DC-B58D-509A-A5B8-FD316A255D89`), then the iPhone 13 Pro Max (`F031FD6D-9E3D-5005-918D-BB860CE37C26`), one at a time. **Never Kaitlyn's phone.** If neither phone is reachable, say so and stop here.
- [ ] **Step 5:** Hand Court the on-device checklist: set a photo, a symbol, remove it, rename; light and dark; the other phone updates; the new-channel sheet; the header tile.
