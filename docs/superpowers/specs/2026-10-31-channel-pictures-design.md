# Channel pictures

Date: 2026-10-31. Mockups: https://claude.ai/artifact/8xMaweMhRxDQp3PBdzKVe3
(five phone screens: today, the new list, channel info, the picker, dark mode).

Calls marked **(Claude's call)** were made while writing this and have not been
confirmed by Court; everything else was agreed in conversation.

## Why

Every channel on the home screen leads with the same "#" square
(`_ChannelTile` in `app/lib/screens/inbox/home_screen.dart`), so the list is a
column of identical glyphs and nothing tells "Trips" from "House" at a glance.
Court wants each channel to have its own picture: a real photo of the two of
them, or a symbol for what the channel is about. Chat apps with group chats
(WhatsApp, Telegram, GroupMe, Locals) all do this.

## Goals

- Every channel shows one of three pictures in the list, the chat-info header
  and the new-channel sheet:
  1. **A photo** the couple picked.
  2. **A symbol** (one of 12 line symbols) on one of 6 soft colours.
  3. **The channel's first letter** on a colour, when nothing has been picked.
     This replaces "#" everywhere.
- Either partner can set, change or remove a channel's picture, and both phones
  show the same one.
- Changing the picture posts a centred line in the chat: "Kaitlyn changed the
  channel picture" / "You changed the channel picture" / "...removed the
  channel picture".
- Renaming a channel posts a matching line: "Kaitlyn renamed the channel to
  Trips". **(Claude's call, so the two kinds of change match. Today a rename
  posts nothing.)**
- The photo and the choice of symbol are end-to-end encrypted. The server
  stores and relays blobs it cannot read.

## Non-goals

- Stickers. Court drew a distinction: a custom sticker set was tried in the
  mockups and rejected in favour of the original 12 line symbols.
- Emoji as channel pictures.
- A picture for the partner chat. Kaitlyn's profile photo already fills that
  row, and the partner chat stays a circle.
- Sending symbols or stickers as chat messages.
- Encrypting channel **names** (that is #105; this design leaves the name
  where it is, but see "Relation to #105").
- Cropping UI. Photos are centre-cropped to a square like profile photos.

## Anti-goals (would make it a failure even if it works)

- Channels looking like people. Channel pictures stay **rounded squares**
  (radius 14 at 52pt, scaled); Kaitlyn stays a circle.
- The server learning anything new about a channel: no plaintext picture, no
  plaintext symbol name.
- A picture change that bumps the in-app unread count, pops the in-app banner
  or plays the in-app chime. (The **push notification** is a known exception,
  agreed with Court: the server pushes an alert for every `Send` and can't read
  bodies, so a picture change or rename line buzzes the partner's phone the way
  a reaction already does. A future "quiet send" is tracked separately; no
  server change here.)
- Old app builds showing raw JSON in the chat (see "Rollout").

## What it looks like

All of this is in the mockups; match them.

### Home list

The leading 52x52 rounded square of each channel row shows:

- **Photo:** the photo, cover-fit, clipped to the square.
- **Symbol:** the symbol (26pt line icon, stroke ~1.8) centred on its tint,
  drawn in that tint's ink colour.
- **Letter:** the first letter of the channel's display name, uppercase, 22pt
  w600, in the ink colour, on a tint chosen from the six by hashing the
  **roomId** (stable across renames). **(Claude's call: roomId, not name.)**

The "New channel" row keeps its "+" tile.

### Channel info page (channels only)

- The header's round 96pt avatar becomes the channel picture: a 96pt rounded
  square (radius ~26) inside the existing 4px card-coloured ring, with a small
  accent camera badge at the bottom right. Tapping it opens the picker sheet.
- A new **Channel picture** row in the THIS CHAT section, showing a 28pt
  thumbnail of the current picture and a chevron. Tapping it opens the same
  sheet.
- The end-to-end line mentions the picture: "Messages, calls, media and this
  channel's picture are end-to-end encrypted. Only you and Kaitlyn can see
  them." **(Claude's call.)**
- The partner chat's info page is unchanged.

### Picker sheet (`conversation/channel_picture_sheet.dart`, new)

A modal bottom sheet:

- Header row: **Cancel** (left), "Channel picture" (centre), **Done** (right).
- A 96pt preview of what will be set, with the channel name under it.
- A two-segment control: **Photo** | **Symbol**.
- Photo tab, a card of three rows:
  - Choose from Photos (`image_picker`, gallery)
  - Take Photo (`image_picker`, camera)
  - Pick from this chat's photos: opens the channel's existing Photos gallery
    (`SharedMediaPage`, tab 0) in a pick mode and uses the chosen image.
    **(Claude's call; Court saw it in the mockup and didn't object.)**
- Symbol tab: a 6x2 grid of the 12 symbols (52pt cells, selected one ringed in
  the accent colour), then a row of 6 colour swatches (48pt targets).
- **Remove picture** (warning colour) at the bottom, shown only when a picture
  is set. It returns the channel to its letter.
- Done sends the change; Cancel discards it. Nothing is sent while browsing.

### New-channel sheet

The "#" in front of the name field (`create_channel_sheet.dart:121`) becomes a
44pt rounded-square button showing the letter tile for the name being typed
(blank-name state: a camera glyph on the neutral tile). Tapping it opens the
picker sheet. Picking is optional, WhatsApp style. The chosen picture is sent
as the channel's first change right after the room is created (the upload
needs the new roomId). If that send fails, the channel still exists with its
letter and a SnackBar says the picture didn't save.

`CreateRoom` carries no request id and `RoomCreated` goes to both members
without saying who created it, so the sheet can't learn its roomId directly.
Hold the pending picture in app-level state (not the sheet, which closes on
send), keyed by the exact name sent, and apply it to the first `RoomCreated`
with that name. **(Claude's call.)** Accepted limits: if both partners create
same-named channels at the same moment the picture may land on the other one,
and if the app is killed before `RoomCreated` arrives the picture is dropped
(the channel keeps its letter). No server change.

### Chat screen header

Inside a channel, the header avatar at the top right (today the partner's
circle, `conversation_page.dart` around :1715-1725, also the tap target into
chat info) shows the channel picture as a rounded square at the same size.
The partner chat keeps Kaitlyn's circle. **(Claude's call; asked, not yet
answered.)**

### Chat line

A centred, muted line in the timeline, styled like `ChatSeparator`
(`conversation/chat_separator.dart`), with its time on long-press like other
rows. "You" for self, the partner's display name otherwise. It breaks bubble
runs like a call row does.

### Home-row preview

When a picture or rename line is the latest thing in a channel, the row
previews it in the muted placeholder tone: "Kaitlyn changed the channel
picture". **(Claude's call.)**

## The 12 symbols and 6 colours

Symbols, keyed by stable wire names: `heart`, `house`, `plane`, `paw`,
`utensils`, `music`, `film`, `star`, `gift`, `sun`, `leaf`, `moon`.

Draw them from **Lucide** (ISC licence; matches the mockup's line style),
bundled as SVG assets and rendered with `flutter_svg` (already a dependency,
pubspec line 34), tinted via `ColorFilter`. Add Lucide's licence to the app's
licence registry. (`plane` in the mockup is Lucide's `send`; the builder may
substitute Lucide `plane` if it reads better.)

Colours, keyed by stable wire names, each a **tint** (background) and an
**ink** (symbol and letter), with light and dark values, added to `AppPalette`
(not raw literals):

| name | light tint | light ink | dark tint | dark ink |
|---|---|---|---|---|
| rose | E8C8D2 | 7E3753 | 5E2C49 | F2CFDD |
| clay | F0D3C7 | 8A4630 | 5A3326 | F5D6CA |
| sand | EEE0CB | 7A5A2E | 4E3F28 | F1E2C9 |
| sage | D3E3D7 | 3F6A4D | 2F4A38 | CFE6D5 |
| sky | D2E0EA | 3A5F7A | 26394A | D3E3F0 |
| lavender | DED5EA | 5B4A7A | 3E3354 | E2D8F0 |

Ink on tint must clear 4.5:1 in both modes (the letter is text); add these
pairs to `test/theme/palette_contrast_test.dart`. Adjust a shade if one fails.

Unknown symbol or colour names (from a newer build) fall back to the letter
tile, never a crash or a blank square.

## How it travels

### A new message kind, not a server field

The picture is sent as an ordinary E2EE message through the existing send path
(`conversation/send_fanout.dart`, outbox, drain), exactly like reactions,
edits and call logs. Nothing changes on the server: it never parses bodies
(`server/src/ws.rs`), the body is far under `MAX_BODY_BYTES`, and messages
replay forever (no retention), so a reinstall or a fresh device rebuilds the
current picture from history.

New `MessageContent` subclass in `conversation/message_content.dart`,
**`ChannelUpdateContent`**, wire kind `channel_update`:

```json
{"v":1,"kind":"channel_update","picture":{"type":"photo", ...AttachmentDescriptor fields}}
{"v":1,"kind":"channel_update","picture":{"type":"symbol","symbol":"plane","color":"sky"}}
{"v":1,"kind":"channel_update","picture":{"type":"none"}}
{"v":1,"kind":"channel_update","name":"Trips"}
```

`picture` and `name` are each optional; a message carries one or the other.
The `name` field is **informational** (it only produces the "renamed" line);
the authoritative name stays the server's `rooms.name`, set by the existing
`RenameRoomFrame`.

Today `RenameRoomFrame` is fire-and-forget (`conn?.send`, dropped offline) and
the server can reject it (`BadName`). So the "renamed" line is sent only
**after** the rename is confirmed: the client remembers its pending rename
(roomId + name) and, when a `RoomRenamedFrame` for that room with that name
arrives, sends the `channel_update` name line through the outbox. A rename
that never lands posts nothing. **(Claude's call.)** While here, the rename
dialog's Save is disabled for an empty or whitespace-only name, since an empty
name turns a channel into the partner-chat shape. **(Claude's call.)**

### Photo upload

Reuse the profile-avatar path:

1. Square and resize the picked image to 512x512 JPEG (q88). Move the existing
   `_squareJpeg` out of `screens/profile/profile_screen.dart` into a shared
   helper so both use it.
2. `encryptFileBytes` (per-file key) and `uploadCiphertext(roomId: <the
   channel's roomId>)`. Uploading to the channel itself (not the couple room
   profiles use) keeps download permission on the server's membership check
   (`ws.rs` blob download).
3. Build a thumbnail with `buildImageThumbnail` (128px edge, 12 KiB max) and
   put the full `AttachmentDescriptor` in the message.

Receiving: `fetchAndDecrypt` (`attachment/attachment_download.dart`) caches the
file under `<appSupport>/attachments/`. The thumbnail renders immediately
while the full image downloads; on download failure keep showing the thumbnail.

### State

- The router (`RoomMessageRouter._ingestMessage`) turns a `channel_update`
  into a timeline `Msg` (like a call row: new nullable fields on `Msg`, e.g. a
  `channelUpdate` payload) and persists it in `MessageDb` (bump
  `schemaVersion`, add the column(s), same apply semantics in memory and DB).
- The **current picture** of a room is the picture from the latest
  `channel_update` carrying `picture` in that room. "Latest" needs an
  **explicit sort**: `MessageStore` is in arrival order (reconcile keeps the
  optimistic row's position), the chat screen sorts by `ts`, and DB hydration
  loads by `id ASC` with UUID ids for unsent rows. Sort by `ts`, then `id`, so
  both phones agree after echoes reconcile. Expose it as a derived per-room
  provider (Riverpod `Provider.family` over the room's `MessageStore`), so it
  hydrates from the DB on launch with no separate store.
- **Optimistic:** your own change shows immediately (it's an optimistic row
  like any send). If the send fails, the line shows the failed state with tap
  to retry, as other messages do, and the picture reverts to the previous one.
  **(Claude's call.)**
- **Concurrent changes:** last one in server order wins on both phones once
  the echo reconciles. Acceptable for two people.

### Rules on the apply path (root CLAUDE.md, "authorize at the apply layer")

- Accept a `channel_update` only in a **channel** room (`RoomShape.chat`).
  One arriving in the partner DM is dropped (not shown, not applied).
- The sender must be a member of the room (the router already only ingests
  member frames; keep that true).
- Either member may change it; no author check beyond membership.

### Unread, banner, chime, search

A `channel_update` does **not** bump unread, show a banner or play the chime
(same treatment as call logs in `read_state_provider.dart` and router
:443-471). It is not indexed in FTS search.

Only two places switch exhaustively on `MessageContent` (the router's
`_ingestMessage` and `outbox/outbox_rehydrate.dart`); the compiler will flag
those. Everything else special-cases call rows with `Msg.callOutcome != null`
and will **not** be flagged, so each needs a manual edit for channel lines:
`MessageDb` persistence (around :640, :674), `read_state_provider.dart` (:86,
unread), `inbox/room_preview.dart` (:111, preview), `wire/message.dart` (:61),
the router's banner switch (has a catch-all), and in `conversation_page.dart`
the reply action (:678), :1353, reactions (:2088) and bubble-run breaking
(:2493). A channel line can't be replied to or reacted to: its long-press shows
only the time. A good guard is a single `Msg.isTimelineEvent` getter covering
call rows and channel lines, used at all these sites.

## Rollout and old builds

An unknown kind currently falls through to `TextContent(raw)`
(`message_content.dart:85`), so builds up to 1.0.0+18 would show a picture
change as a text bubble of raw JSON, and count it as unread.

- Add forward compatibility in this change: a `v:1` envelope with an
  **unknown** kind decodes to a new `UnsupportedContent`. The router keeps it
  as a **hidden** row (persisted with its raw body in `MessageDb`, which is
  SQLCipher-encrypted and already stores plaintext bodies; never rendered, no
  unread, no chime). Dropping it instead would lose it for good on that
  device, because the replay high-water mark moves past it. A later build that
  understands the kind re-decodes hidden rows on hydrate. **(Claude's call;
  the builder should confirm where bodies are decoded on load and put the
  re-decode there.)** Only the not-JSON / not-v1 case stays plain text
  (legacy and cannot-decrypt sentinel behaviour).
- For this release, both phones must update before either sets a picture.
  There are exactly two users, both on TestFlight. **(Claude's call: no
  two-step release.)**

## Sign-out

Add to `identity/sign_out.dart` (awaited):

- The new `MessageDb` columns go with the DB wipe (already cleared).
- Delete `<appSupport>/attachments/`, which now holds decrypted channel
  pictures. It currently survives sign-out for all media, a pre-existing gap;
  closing it here is in scope. **(Claude's call.)**
- Invalidate the new picture provider.

## Crash reporting

`reportFault` contexts are constants (`channel_picture_upload`,
`channel_picture_apply`). Never include the channel name, symbol choice, blob
key or file path. A malformed `channel_update` is reported as a constant
`FormatException`. New identifying keys (if any) go into both scrub lists
(`diagnostics/scrub.dart`, `server/src/scrub.rs`).

## Relation to #105

#105 wants channel names encrypted end to end. This design's
`channel_update.name` already carries the name encrypted inside the room; a
later #105 change could make it authoritative and drop the plaintext column.
Out of scope here; don't block on it.

## Testing

Name tests as invariants, condition-based waits (`test/support/widget_waits.dart`).

- `ChannelUpdateContent` encode/decode round trip for photo, symbol, none and
  name; unknown symbol/colour decode without throwing.
- `MessageContent.decode` of an unknown `v:1` kind yields `UnsupportedContent`;
  the router drops it with no unread, banner or chime.
- A `channel_update` in the partner DM is ignored.
- Current picture is the latest update in timeline order, including after the
  optimistic row reconciles to its server id, and after a DB re-hydrate.
- A failed picture send reverts the picture and shows retry.
- Home row shows photo / symbol / letter tile; letter colour is stable across a
  rename; partner row still a circle.
- Chat-info header tap and the Channel picture row both open the sheet; Done
  sends, Cancel doesn't; Remove returns to the letter.
- New-channel sheet: picking a picture sends it after `RoomCreated`; skipping
  leaves the letter.
- Rename sends both `RenameRoomFrame` and a `channel_update` name line.
- Palette contrast for all six ink/tint pairs in light and dark.
- Sign-out deletes the attachments folder.
- Touch targets ≥ 44pt on every new control.

On device (Court's phone, then the 13 Pro Max; never Kaitlyn's): set a photo,
a symbol, remove it, rename, check light and dark, and check the second phone
updates.

## Left to the builder

- Exact file split for the tile widget (suggest `inbox/channel_tile.dart`,
  used by home, chat info, the chat header, the sheet preview and the create sheet).
- Whether `Msg` carries the update as one payload field or a few columns.
- How the pick mode on `SharedMediaPage` is wired (a callback returning the
  chosen item is the expected shape).
- Issue/PR breakdown.
