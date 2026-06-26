# Edit messages — design

**Date:** 2026-06-25
**Status:** Approved, ready for implementation plan

## Goal

Let you fix a message you already sent. Long-press one of your own text
bubbles, tap **Edit**, the composer pre-fills with the message text, you change
it and send. Both you and your partner then see the corrected text with a small
**"edited"** marker. There is no time limit and no version history: the edit
replaces the body, exactly like an unsend replaces the message with a tombstone.

This mirrors the existing **unsend** (`kind:"delete"`) and **reaction**
(`kind:"reaction"`) flows. Editing is a new body-borne control action carried as
an opaque encrypted frame; the server stays a dumb relay and needs **no
changes**.

## Constraints / context

- **Couples-only.** Every room is exactly the two partners. "Your partner" is a
  single unambiguous person.
- **E2EE, server is opaque.** Both partners share the room key, so either side
  can craft a valid encrypted frame naming *any* message id. Per CLAUDE.md,
  authorization for body-borne actions is enforced **at the apply layer**, not
  in the UX. An edit whose target the requester did not author is dropped.
- **Server unchanged.** Edits travel as ordinary `SendFrame` messages (per-
  recipient fan-out ciphertext). The server mints a row, fans out, echoes the
  self-copy for reconcile — identical to delete/reaction. No new endpoints, no
  schema migration on the server.
- **No data migrations** (CLAUDE.md): any client-side SQLite change is
  schema-only (`ADD COLUMN`, nullable).

## Scope

In scope:

- Edit **your own** messages.
- **Text messages only** (the `TextContent` kind).
- **No time limit** — any of your past text messages is editable.
- A visible **"edited"** marker on edited bubbles.
- Edit only on messages that are actually on the server (`sent` / `read`).

Out of scope (deferred, not built now):

- Editing file/audio **captions**, call entries, or reactions.
- Edit **history** / "see original". The edit overwrites the body.
- A time-limited edit window or "edit expired" state.
- Inline-in-bubble editing (we use the composer flow instead).

## Behavior

- **Entry point.** The long-press reaction bar gains an **Edit** action,
  rendered only when the message is mine, its content is text, and its
  `sendStatus` is `sent` or `read`. (A `sending`/`failed` message isn't on the
  server yet — there's nothing remote to edit; you cancel and retype as today.)
- **Composer edit mode.** Tapping Edit puts the composer into an edit mode for
  one target message id:
  - A banner appears above the input: a pencil icon, "Editing message", a
    one-line preview of the current text, and an ✕ to cancel.
  - The text field pre-fills with the message's current text, cursor at the end.
  - The send button sends the **edit** instead of a new message.
  - Cancel (✕, or clearing the field to empty and dismissing) returns to normal
    compose. Sending an empty edit is a no-op cancel, **not** a delete.
- **Edit-in-progress is transient.** Backgrounding the app, switching rooms, or
  taking another bubble action silently cancels edit mode. Nothing is persisted
  for an unsent edit.
- **Apply (both sides).** On send, the edit is applied optimistically locally
  and enqueued to the outbox; the partner applies it on receipt. Applying
  replaces the message's text and sets its "edited" flag.
- **Read status is preserved.** Editing does **not** reset `read`. If the
  partner already read the message, it stays read; they just see new text +
  "edited". Matches iMessage/Telegram.
- **Link previews.** If the edited text changes URLs, the edit re-runs the same
  Open Graph fetch a normal text send does, so the preview matches the new text
  (reusing the existing send-path preview logic). An edit that removes the URL
  clears the preview.
- **Out-of-order safety.** If an edit frame arrives before its target row exists
  (target not yet received, or the optimistic→server-id reconcile hasn't landed
  — routinely the case when the original was a delayed link-preview send), the
  edit is stashed in a deferred map and re-applied in `add`/`reconcile`, exactly
  like `_read` / `_deleted` / `_cancelled` today. Last-write-wins by edit frame
  arrival; a couples app has no concurrent-editor problem (only the author edits).

## Wire format

New plaintext envelope kind, alongside the existing text/file/audio/reaction/
delete/call envelopes:

```json
{ "v": 1, "kind": "edit", "target": "<server-id>", "text": "<new text>",
  "preview": { ... optional link preview ... } }
```

`target` is the **server id** of the message being edited (edits are only
offered on `sent`/`read` messages, which always have a server id). Decoding an
unknown kind continues to fall back to text, preserving back-compat.

## Components

Client only. No server code.

- **`message_content.dart` — `EditContent`.** New sealed-class case carrying
  `target`, `text`, and optional `preview`; `encode()`/`decode()` for the
  envelope above; a new `'edit'` arm in `MessageContent.decode`.
- **`message_store.dart` — `applyEdit` + deferred edits.** New
  `applyEdit(targetId, {required requestedBy, required text, preview})` that:
  1. Drops the edit if the target row exists and `target.from != requestedBy`
     (spoof guard — the core invariant).
  2. If the target isn't present yet, records it in a deferred `_edited`
     map keyed by `targetId` (latest edit wins) and returns.
  3. Otherwise replaces the row's text/preview and sets its edited flag.
  `add` and `reconcile` consult `_edited` and apply a pending edit when the row
  lands (and re-validate authorship there too).
- **`Msg` (`wire/message.dart`) — edited flag.** Add `edited: bool`, carried
  through `copyWith`. A boolean is all the "edited" marker needs; we deliberately
  do **not** store an edit timestamp or history (deferred, see Scope).
- **`message_db.dart` — persistence.** Schema-only `ADD COLUMN edited INTEGER
  NOT NULL DEFAULT 0`. `applyEdit` updates the cached `body`/preview + `edited`
  for the target row, mirroring the store's authorship check.
- **`room_message_router.dart` — dispatch.** New `content is EditContent` arm
  that calls `store.applyEdit(...)` + `db.applyEdit(...)` and drops the matching
  outbox row on the self-copy echo, exactly like the delete/reaction arms.
- **`home_screen.dart` — send orchestration.** `_sendEdit(ref, room, targetId,
  newText)`: build the optimistic local apply, encode `EditContent` (with
  preview fetch reusing the text-send path), `buildSendFrame` fan-out, enqueue to
  outbox. Pass an `onEdit` callback down to `ConversationPage`.
- **`conversation_page.dart` — UI.** Add the **Edit** action to the reaction-bar
  overlay (gated by mine + text + sent/read); add composer edit-mode state
  (`_editingId`), the editing banner, pre-fill, send-button behavior swap, and
  cancel; render the "edited" marker on edited bubbles.

## Authorization (the security-critical part)

Per CLAUDE.md "Authorize body-borne actions at the apply layer": the spoof guard
lives in `MessageStore.applyEdit` (and is re-checked when a deferred edit applies
in `add`/`reconcile`), **not** only in the UI gate. The UI only offering Edit on
your own bubbles is convenience, not enforcement — a partner could hand-craft an
`edit` frame targeting one of *your* messages, and the apply layer must reject
it because `target.from != requestedBy`. `message_db.applyEdit` repeats the same
check so the persisted cache can't be poisoned either.

## Error handling

- **Send fails / offline.** The edit sits in the durable outbox and retries like
  any message; the optimistic local edit stays applied. (Consistent with how
  delete/reaction behave offline.)
- **Empty edit.** Sending an empty/whitespace-only edit cancels edit mode with
  no frame sent. It is never interpreted as a delete.
- **Target gone.** If the target was unsent (tombstoned) before an inbound edit
  applies, the edit is dropped (a tombstoned id is not resurrected, matching the
  existing reconcile/tombstone guard).
- **Spoofed edit.** Dropped at the apply layer (see Authorization).

## Testing

Dart unit tests (host VM, like the existing store/content tests):

- `EditContent` encode/decode round-trip; unknown-kind back-compat fallback.
- `applyEdit` updates text + sets edited flag on an owned message.
- `applyEdit` **drops** an edit whose `target.from != requestedBy` (spoof guard).
- Deferred edit: `applyEdit` before the target arrives, then `add`/`reconcile`
  applies it; spoofed deferred edit is still dropped on apply.
- Edit does not change `read` status; tombstoned target is not resurrected.
- `message_db.applyEdit` persists text/edited and enforces authorship.
- Router: an inbound `EditContent` self-copy echo drops the outbox row.

Widget test (best effort, matching existing conversation tests): entering edit
mode pre-fills the composer and shows the banner; sending swaps text + shows the
"edited" marker; cancel restores normal compose.

Note: per CLAUDE.md, a green `flutter test`/`analyze` does not prove the iOS
build works — build to **both** physical phones (Court's iPhone 17 Pro Max +
the iPhone 13 Pro Max, never Kaitlyn's) via `ios-deploy.sh` before claiming done,
and verify an edit round-trips between the two devices.

## Rollout / compatibility

- **Old clients** receiving an `edit` frame fall back to `TextContent` (unknown
  kind → text), so the edit frame renders as a stray text bubble at worst on a
  client that predates this feature. Since both partners are this app and ship
  together, this is a non-issue in practice but the fallback keeps it safe.
- No server deploy, no migration coordination. Pure client release.
