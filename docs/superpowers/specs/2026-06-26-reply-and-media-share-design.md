# Reply/quote a message + save/share received media

Date: 2026-06-26
Issue: #56
Branch: `worktree-reply-and-media-share`

## Summary

Two chat affordances, landed together on one branch:

1. **Reply / quote a specific message** — a new send can quote an earlier
   message. The quote renders as a snippet above the new bubble; tapping it
   scroll-jumps to the original. Triggered by swipe-to-reply on a bubble and
   by a "Reply" action in the long-press menu.
2. **Save / share received media** — a Share-sheet action (and the
   already-existing Save to Photos) reachable from the full-screen viewer and
   from the bubble long-press menu.

Scope: iOS-only MVP, 2-person couples app.

## Prior state (what already exists)

- **Content model** (`app/lib/conversation/message_content.dart`) is a
  versioned (`v:1`) sealed-class envelope: `TextContent`, `FileContent`,
  `AudioContent`, plus action kinds (`reaction`, `delete`, `edit`, `call`).
  Unknown JSON keys are ignored on decode, so adding an optional key is
  v1-compatible.
- **`Msg`** (`app/lib/wire/message.dart`) carries ingest-time metadata
  (`attachment`, `linkPreview`, `reactions`, `callOutcome`, `edited`) threaded
  through `copyWith`.
- **Jump/highlight** (`_focusMessage`, `conversation_page.dart` ~482–529)
  already loads full history from the DB, scrolls the target into view with a
  highlight, and **silently no-ops if the target isn't found** (e.g. since
  unsent). Directly reusable for tap-to-jump.
- **Long-press menu** (`conversation_page.dart`): a reaction bar plus an
  `_actions()` column of `_actionItem`s (Copy / Edit / Delete). New actions
  slot in here.
- **Save to Photos already works** in `AttachmentViewer`
  (`app/lib/attachment/attachment_viewer.dart`) via the `gal` package
  (top-right download button, add-only Photos access).
- `Info.plist` already has `NSPhotoLibraryAddUsageDescription` +
  `NSPhotoLibraryUsageDescription`.
- `gal` is a dependency; **`share_plus` is not** (must be added).

## Feature 1 — Reply / quote

### 1.1 Wire & content

Add an optional reply reference carried **inside the encrypted body** of the
three renderable content kinds (`TextContent`, `FileContent`, `AudioContent`):

```
ReplyRef {
  id:     String        // target message's server id
  author: String        // target's `from` username (for the quote label)
  kind:   String         // text | photo | video | voice | file
  text:   String?        // ≤140-char excerpt; present only for text/captions
}
```

- Encoded as a nested `"replyTo": { ... }` key in each content's JSON
  envelope. Absent when the send is not a reply. Old clients ignore the
  unknown key (v1-compatible).
- `kind` lets the quote render "📷 Photo" / "🎤 Voice message" without an
  excerpt; `text` carries the excerpt for text messages and captioned media.

### 1.2 Store & Msg

- `Msg` gains `final ReplyRef? replyTo;`, set at construction from the decoded
  content (next to `attachment`/`linkPreview`), and threaded through
  `copyWith`.
- Because `replyTo` is immutable per-message metadata, it flows through
  `add` / `reconcile` / `setAll` for free via the `Msg` field — **no new
  deferred-state maps** (unlike `_read` / `_deleted` / `_edited`).
- **One required touch:** `MessageStore._withEdit` rebuilds `Msg` by hand
  (not `copyWith`), so it must explicitly preserve `base.replyTo` — editing a
  reply's text must not drop its quote.

### 1.3 E2EE / authorization

A reply is an ordinary text/file/audio send that merely *references* an id; the
receiver renders the quote but **never acts** on the referenced id. So unlike
`delete`/`edit`, there is **no privileged body-borne action** and no
apply-layer authorization to add. The only "validation" is rendering:
**prefer the live message in the store over the cached snippet** (so the quote
reflects later edits and supports tap-to-jump), falling back to the cached
`ReplyRef` snippet when the original isn't loaded.

### 1.4 UI (`conversation_page.dart`)

- **Quoted header in the bubble:** a small bar above a reply's bubble showing
  the reply author + snippet. Source of truth: the live target message when
  present (reflects edits); else the cached `ReplyRef`.
- **Tap-to-jump:** tapping the quote calls the existing
  `_focusMessage(replyTo.id)`. Present → scroll + highlight. Gone / not in
  history → silent no-op (per existing `_focusMessage` behavior). No new jump
  logic, no toast.
- **Swipe-to-reply:** a horizontal drag on a bubble toward screen center
  (own bubbles drag left, partner's drag right, WhatsApp-style) past a
  threshold reveals a reply arrow + haptic and sets the reply context on
  release. Allowed on text / file / **voice** bubbles; **excluded** on
  call-log rows.
- **Reply action in the long-press menu:** a new `_actionItem` ("Reply")
  alongside Copy / Edit / Delete, same allow/exclude rules.
- **Composer reply chip:** a dismissible quoted bar above the text input
  (author + snippet + ✕). Set when reply is picked; the next send attaches the
  `ReplyRef`; sending or tapping ✕ clears it.

## Feature 2 — Save / share received media

- **Add `share_plus`** as a dependency. Share the **decrypted on-disk file**
  (the same artifact the viewer / `attachment_download` already produce) as an
  `XFile` into the iOS share sheet.
- **Viewer (`attachment_viewer.dart`):** add a **Share** button beside the
  existing Save button in the app bar. (Save already present.)
- **Bubble long-press menu:** for image/video file bubbles, add **Save to
  Photos** and **Share** `_actionItem`s. These need the decrypted file, so the
  menu action runs the same decrypt-then-act path that `onOpenAttachment`
  uses, then calls the action.
- **Refactor:** lift the viewer's `gal` save logic (`_saveToGallery`) into a
  small shared helper so the bubble menu and the viewer share one
  implementation rather than duplicating it.

## Testing

Unit (store / content):
- `ReplyRef` round-trips through `MessageContent.encode`/`decode` for text,
  file, and audio kinds.
- A v1 envelope **without** `replyTo` still decodes (back-compat).
- `replyTo` survives `add`, `reconcile`, and `setAll`.
- An `edit` applied to a reply message preserves `replyTo` (regression guard on
  `_withEdit`).

Widget:
- A reply bubble renders its quote from the **live** target message, and from
  the **cached** `ReplyRef` when the target is absent.
- Tapping the quote invokes the focus/jump path.
- A swipe past threshold sets the composer reply context; ✕ clears it.

iOS build:
- `share_plus` is a **new plugin** — a green `flutter test` / `flutter
  analyze` does not prove the iOS build (host VM never compiles the iOS plugin
  impl). **Build to a device** (`scripts/ios-deploy.sh`) before claiming the
  share sheet works. `share_plus` has no MLKit dependency, so the
  simulator-arch caveat does not apply.

## Out of scope

- Forwarding a message to another room (couples app — only one room).
- Reply to call-log rows or reactions.
- Save/share for non-media file kinds beyond what the share sheet offers
  generically (share works on any file; "Save to Photos" is image/video only).
