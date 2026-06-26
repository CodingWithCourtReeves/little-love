# Reply/quote + media save/share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let either partner reply-quote an earlier message (swipe + menu, with tap-to-jump) and save/share received media from the viewer and the bubble menu.

**Architecture:** A reply rides as an optional `ReplyRef` inside the encrypted body of `TextContent`/`FileContent`/`AudioContent`; it threads through `Msg` (a plain immutable field) into the store, the SQLCipher cache (new v4 column), the ingest router, and the send path. The quote renders from the live target message when present, else the cached snippet, and tapping it reuses `_focusMessage`. Media save/share adds `share_plus`, a shared `gal` save helper, and Share/Save actions on the viewer + bubble menu.

**Tech Stack:** Flutter, Riverpod, sqflite_sqlcipher, `gal`, `share_plus` (new), `video_player`.

## Global Constraints

- iOS-only MVP, 2-person couples app. No group/forward semantics.
- Content envelope is `v:1`; new keys must be additive (old clients ignore unknown keys). No version bump of the envelope.
- E2EE: a reply only *references* an id; the receiver never acts on it, so **no apply-layer authorization** is added (unlike delete/edit).
- No em dashes in user-facing copy.
- DB rule: the SQLCipher file is a rebuildable cache — a deterministic ALTER + self-row backfill in `onUpgrade` is allowed here (this rule's strictness is for the *server* Postgres migrations).
- `share_plus` is a new iOS plugin: a green `flutter test`/`analyze` does not prove the iOS build. Build to a device before claiming the share sheet works.
- Run before pushing: `dart format`, `flutter analyze`, full `flutter test`.

---

### Task 1: `ReplyRef` model + content envelope wiring

**Files:**
- Create: `app/lib/conversation/reply_ref.dart`
- Modify: `app/lib/conversation/message_content.dart` (TextContent ~78, FileContent ~199, AudioContent ~220, and `decode` ~16)
- Test: `app/test/conversation/message_content_test.dart` (add cases; create if absent)

**Interfaces:**
- Produces: `class ReplyRef { final String id, author, kind; final String? text; ReplyRef.fromJson(Map); Map<String,Object?> toJson(); }` with `kind ∈ {text,photo,video,voice,file}`.
- Produces: `TextContent`, `FileContent`, `AudioContent` each gain `final ReplyRef? replyTo;` (named, optional), encoded as `"replyTo"` and decoded back.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/conversation/message_content_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:little_love/conversation/message_content.dart';
import 'package:little_love/conversation/reply_ref.dart';

void main() {
  test('TextContent round-trips a replyTo', () {
    final c = TextContent('ok', replyTo: const ReplyRef(
        id: 'm1', author: 'court', kind: 'text', text: 'original'));
    final back = MessageContent.decode(c.encode());
    expect(back, isA<TextContent>());
    final r = (back as TextContent).replyTo!;
    expect(r.id, 'm1');
    expect(r.author, 'court');
    expect(r.kind, 'text');
    expect(r.text, 'original');
  });

  test('FileContent round-trips a replyTo without excerpt', () {
    final desc = decodeSampleDescriptor(); // see helper below
    final c = FileContent(desc, caption: 'hi', replyTo:
        const ReplyRef(id: 'm2', author: 'kaitlyn', kind: 'photo'));
    final back = MessageContent.decode(c.encode()) as FileContent;
    expect(back.replyTo!.kind, 'photo');
    expect(back.replyTo!.text, isNull);
  });

  test('a v1 envelope without replyTo still decodes', () {
    final back = MessageContent.decode(const TextContent('hi').encode());
    expect((back as TextContent).replyTo, isNull);
  });
}
```

Use the existing descriptor sample pattern from other tests for `decodeSampleDescriptor` (grep `AttachmentDescriptor(` in `test/` for a minimal constructor); if none, build one inline with required fields.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/message_content_test.dart`
Expected: FAIL (`reply_ref.dart` missing / `replyTo` not a param).

- [ ] **Step 3: Create `reply_ref.dart`**

```dart
// app/lib/conversation/reply_ref.dart

/// A reference to the message a reply quotes. Rides inside the encrypted body
/// of a text/file/audio send (see [MessageContent]). The receiver renders a
/// quote from this snippet, but never *acts* on [id] — so unlike delete/edit
/// there is no privileged action to authorize at the apply layer. When the
/// target is in the buffer the UI prefers the live message (reflecting edits);
/// this cached snippet is the fallback when it is not loaded.
class ReplyRef {
  const ReplyRef({
    required this.id,
    required this.author,
    required this.kind,
    this.text,
  });

  /// Target message's server id (used for tap-to-jump via _focusMessage).
  final String id;

  /// Target's `from` username — the quote's attribution label.
  final String author;

  /// One of: text | photo | video | voice | file. Lets the quote render
  /// "Photo"/"Voice message" without an excerpt.
  final String kind;

  /// ≤140-char excerpt; present only for text messages (and captions).
  final String? text;

  Map<String, Object?> toJson() => {
    'id': id,
    'author': author,
    'kind': kind,
    if (text != null && text!.isNotEmpty) 'text': text,
  };

  factory ReplyRef.fromJson(Map<String, Object?> j) => ReplyRef(
    id: (j['id'] as String?) ?? '',
    author: (j['author'] as String?) ?? '',
    kind: (j['kind'] as String?) ?? 'text',
    text: j['text'] as String?,
  );
}
```

- [ ] **Step 4: Wire into `message_content.dart`**

Add `import 'reply_ref.dart';`. In `decode`, parse a shared `replyTo` once before the switch's text/file/audio arms:

```dart
ReplyRef? replyOf(Map<String, Object?> j) {
  final r = j['replyTo'];
  return r is Map ? ReplyRef.fromJson(Map<String, Object?>.from(r)) : null;
}
```

- `TextContent`: add `this.replyTo` to ctor, `final ReplyRef? replyTo;`, and in `encode()` add `if (replyTo != null) 'replyTo': replyTo!.toJson(),`. In `decode`'s `case 'text'`, pass `replyTo: replyOf(j)`.
- Same for `FileContent` (`case 'file'`) and `AudioContent` (`case 'audio'`).

- [ ] **Step 5: Run to verify it passes**

Run: `cd app && flutter test test/conversation/message_content_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/reply_ref.dart app/lib/conversation/message_content.dart app/test/conversation/message_content_test.dart
git commit -m "feat(reply): ReplyRef model carried in the content envelope (#56)"
```

---

### Task 2: `Msg.replyTo` field + store preservation

**Files:**
- Modify: `app/lib/wire/message.dart` (ctor ~9, fields, `copyWith` ~91)
- Modify: `app/lib/conversation/message_store.dart` (`_withEdit` ~92)
- Test: `app/test/conversation/message_store_test.dart` (add cases)

**Interfaces:**
- Consumes: `ReplyRef` (Task 1).
- Produces: `Msg` gains `final ReplyRef? replyTo;` (named, optional, default null), preserved by `copyWith` and `MessageStore._withEdit`.

- [ ] **Step 1: Write the failing test**

```dart
// in app/test/conversation/message_store_test.dart
test('replyTo survives add/reconcile and an intervening edit', () {
  final store = container.read(messageStoreProvider('r').notifier);
  final reply = const ReplyRef(id: 'orig', author: 'court', kind: 'text', text: 'q');
  store.add(Msg(id: 'c1', from: 'court', to: 'r', body: 'hi', ts: t0,
      clientMsgId: 'c1', replyTo: reply));
  store.reconcile('c1', Msg(id: 's1', from: 'court', to: 'r', body: 'hi',
      ts: t0, replyTo: reply));
  expect(store.state.single.replyTo!.id, 'orig');
  store.applyEdit('s1', requestedBy: 'court', text: 'hi2');
  expect(store.state.single.body, 'hi2');
  expect(store.state.single.replyTo!.id, 'orig'); // edit preserves the quote
});
```

Match the file's existing harness (look at its top for `container`, `t0`, imports; add the `reply_ref.dart` import).

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/message_store_test.dart`
Expected: FAIL (`replyTo` not a param of `Msg`).

- [ ] **Step 3: Add the field to `Msg`**

In `message.dart`: add `import '../conversation/reply_ref.dart';`, `this.replyTo,` to the ctor, `final ReplyRef? replyTo;` (doc: "Set when this message is a reply; carried in the encrypted body, like [linkPreview]."), `ReplyRef? replyTo,` to `copyWith` params, and `replyTo: replyTo ?? this.replyTo,` to the returned `Msg`.

- [ ] **Step 4: Preserve in `_withEdit`**

In `message_store.dart` `_withEdit`, add `replyTo: base.replyTo,` to the hand-built `Msg(...)` (it rebuilds by hand, so without this an edit drops the quote).

- [ ] **Step 5: Run to verify it passes**

Run: `cd app && flutter test test/conversation/message_store_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/wire/message.dart app/lib/conversation/message_store.dart app/test/conversation/message_store_test.dart
git commit -m "feat(reply): thread replyTo through Msg + preserve it across edit (#56)"
```

---

### Task 3: Ingest router + SQLCipher persistence

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart` (Text/File/Audio arms ~332-363)
- Modify: `app/lib/conversation/message_db.dart` (schema ~46-65, `schemaVersion` :24, `onUpgrade` ~88, `_toRow` ~534, `_fromRow` ~555)
- Test: `app/test/conversation/message_db_test.dart`, `app/test/conversation/room_message_router_test.dart`

**Interfaces:**
- Consumes: `Msg.replyTo` (Task 2), `MessageContent` arms now exposing `replyTo` (Task 1).
- Produces: persisted + replayed `replyTo`; ingest sets it on Text/File/Audio rows.

- [ ] **Step 1: Write failing persistence test**

```dart
// in app/test/conversation/message_db_test.dart
test('persists and reloads replyTo', () async {
  final db = MessageDb.test(await openTestDb()); // match existing helper
  final reply = const ReplyRef(id: 'o', author: 'court', kind: 'photo');
  await db.add(Msg(id: 's1', from: 'court', to: 'r', body: 'hi', ts: t0,
      replyTo: reply));
  final rows = await db.messagesFor('r');
  expect(rows.single.replyTo!.kind, 'photo');
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: FAIL (column missing / field dropped).

- [ ] **Step 3: Add the column + bump version**

In `message_db.dart`: bump `schemaVersion = 4`; add `reply_to TEXT,` to the `onCreate` table; append to `onUpgrade`:

```dart
if (oldV < 4) {
  // Reply/quote metadata, JSON-encoded ReplyRef. Schema-only ALTER with a
  // default null; existing rows read as non-replies.
  await db.execute('ALTER TABLE messages ADD COLUMN reply_to TEXT');
}
```

In `_toRow` add `'reply_to': m.replyTo == null ? null : jsonEncode(m.replyTo!.toJson()),`. In `_fromRow` add `replyTo: r['reply_to'] == null ? null : ReplyRef.fromJson(jsonDecode(r['reply_to'] as String) as Map<String, Object?>),`. Add `import 'reply_ref.dart';`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the ingest router**

In `room_message_router.dart`, the three arms: destructure `:final replyTo` and add `replyTo: replyTo,` to each `Msg(...)`:
- `TextContent(:final text, :final preview, :final replyTo) => Msg(... replyTo: replyTo)`
- `FileContent(:final descriptor, :final caption, :final replyTo) => Msg(... replyTo: replyTo)`
- `AudioContent(:final descriptor, :final caption, :final replyTo) => Msg(... replyTo: replyTo)`

Add a router test asserting an inbound reply lands with `replyTo` set (mirror the existing "inbound partner message is persisted" test).

- [ ] **Step 6: Run + commit**

Run: `cd app && flutter test test/conversation/`
Expected: PASS.

```bash
git add app/lib/conversation/room_message_router.dart app/lib/conversation/message_db.dart app/test/conversation/
git commit -m "feat(reply): persist + ingest replyTo (db v4, router) (#56)"
```

---

### Task 4: Send path threads the reply context

**Files:**
- Modify: `app/lib/screens/inbox/home_screen.dart` (`_sendMessage` text send ~330-368, `_sendAttachment` ~402-470)
- Modify: `app/lib/outbox/outbox_rehydrate.dart` (~108-130)
- Modify: `app/lib/conversation/conversation_page.dart` (composer → onSend callback signature)
- Test: extend send/outbox tests if present; else covered by Task 5 widget test + manual.

**Interfaces:**
- Consumes: `TextContent(..., replyTo:)`, `FileContent(..., replyTo:)`, `Msg.replyTo`.
- Produces: `_sendMessage`/`_sendAttachment` accept `ReplyRef? replyTo`; the onSend callback from the composer carries the active reply target.

- [ ] **Step 1:** Thread `ReplyRef? replyTo` into `_sendMessage`. Pass it to both the optimistic `Msg(... replyTo: replyTo)` (the `msgs.add(Msg(...))` at ~338) and `TextContent(text, preview: preview, replyTo: replyTo).encode()` at ~365.

- [ ] **Step 2:** Same for `_sendAttachment`: add the param, pass `replyTo:` to `FileContent(descriptor, caption: caption, replyTo: replyTo)` and to the optimistic `Msg(...)` at ~465.

- [ ] **Step 3:** Outbox rehydrate (`outbox_rehydrate.dart`): the rehydrate destructures content to rebuild an optimistic `Msg` after a cold start. Add `replyTo` to the destructure tuples (~112-118) and pass it into the rebuilt `Msg` so a reply queued before a kill still shows its quote on relaunch.

- [ ] **Step 4:** Plumb the reply context: `conversation_page.dart` already owns the composer; add a `ReplyRef? _replyDraft` state set by swipe/menu (Task 5), pass it through the existing send callback up to `home_screen`'s `_sendMessage`/`_sendAttachment`, and clear it after a send is enqueued. (Exact callback name: grep the composer's `onSend`/`onSubmit` in `conversation_page.dart`.)

- [ ] **Step 5:** Run `cd app && flutter analyze` (no analyzer errors) and `flutter test`. Commit:

```bash
git add app/lib/screens/inbox/home_screen.dart app/lib/outbox/outbox_rehydrate.dart app/lib/conversation/conversation_page.dart
git commit -m "feat(reply): carry reply context through the send + outbox path (#56)"
```

---

### Task 5: Reply UI — quote, jump, swipe, menu, composer chip

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (bubble build ~1275-1470, `_actions()` ~2865, `_focusMessage` reuse ~482, composer)
- Create helper: a small `_buildReplyExcerpt(Msg)` for the cached/live snippet text.
- Test: `app/test/conversation/conversation_page_test.dart` (or the page's existing widget test file)

**Interfaces:**
- Consumes: `Msg.replyTo`, `_focusMessage(String id)`, the store provider, `_replyDraft` (Task 4).
- Produces: visible quote header, swipe-to-reply gesture, "Reply" menu action, composer reply chip.

- [ ] **Step 1: Quoted header in the bubble.** Where a bubble is built, if `m.replyTo != null`, render a tappable header above the bubble body. Resolve the label: look up `store.firstWhereOrNull((x) => x.id == m.replyTo!.id)`; if found, derive author + excerpt from the *live* message (text → body excerpt, attachment → kind label); else fall back to `m.replyTo!.author` + (`m.replyTo!.text` ?? kind label). Kind label map: `photo→'Photo'`, `video→'Video'`, `voice→'Voice message'`, `file→'File'`. Wrap in `GestureDetector(onTap: () => _focusMessage(m.replyTo!.id), child: ...)`.

- [ ] **Step 2: Tap-to-jump test.** Widget test: render a bubble whose `replyTo.id` points at a present message; tap the quote; assert the list scrolled / `_highlightedId` set. (`_focusMessage` already no-ops when absent — assert no throw for a missing target.)

- [ ] **Step 3: "Reply" menu action.** In `_actions()` add an `_actionItem(key: 'action-reply', icon: Icons.reply, label: 'Reply', onTap: widget.onReply!)` before Copy, gated on a new `final VoidCallback? onReply;` wired only for text/file/audio bubbles (not call-log rows). Setting it sets `_replyDraft = _replyRefFor(m)` and dismisses the menu.

- [ ] **Step 4: Swipe-to-reply.** Wrap the bubble in a horizontal-drag detector (own bubbles drag left, partner's drag right). On drag past ~64px: `HapticFeedback.lightImpact()` + set `_replyDraft`. Reveal a reply arrow proportional to drag. Exclude call-log rows. Reuse the existing gesture layering — check the bubble already has `onLongPressStart`; add `onHorizontalDragUpdate`/`onHorizontalDragEnd` without breaking vertical scroll (use a translation animation, snap back on release).

- [ ] **Step 5: Composer reply chip.** Above the text input, when `_replyDraft != null`, show a dismissible bar: a left accent, "Replying to {author}", the excerpt, and a ✕ that clears `_replyDraft`. On send (Task 4 callback) pass `_replyDraft` then clear it.

- [ ] **Step 6:** `_replyRefFor(Msg m)` helper builds a `ReplyRef` from a live message: `kind` from attachment mime (`image/*`→photo, `video/*`→video, audio→voice, else file) or `text`; `text` = `m.body` truncated to 140 chars for text messages; `author` = `m.from`.

- [ ] **Step 7:** Run `cd app && flutter test test/conversation/` + `flutter analyze`. Commit:

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/
git commit -m "feat(reply): quote header, tap-to-jump, swipe + menu reply, composer chip (#56)"
```

---

### Task 6: Add `share_plus` + shared save helper + viewer Share button

**Files:**
- Modify: `app/pubspec.yaml` (deps ~59)
- Create: `app/lib/attachment/media_actions.dart` (shared `saveToGallery` + `shareFile`)
- Modify: `app/lib/attachment/attachment_viewer.dart` (lift `_saveToGallery` to helper ~29; add Share action ~88)

**Interfaces:**
- Produces: `Future<void> saveToGallery(File file, AttachmentDescriptor d)` and `Future<void> shareFile(File file, AttachmentDescriptor d)` in `media_actions.dart`.

- [ ] **Step 1:** Add `share_plus: ^10.1.4` under `gal:` in `pubspec.yaml`. Run `cd app && flutter pub get`. (Confirm the resolved version installs; bump if pub picks a different compatible one.)

- [ ] **Step 2:** Create `media_actions.dart` with `saveToGallery` (move the `gal` logic out of the viewer verbatim — `Gal.hasAccess`/`requestAccess`/`putVideo`/`putImage`) and `shareFile`:

```dart
import 'dart:io';
import 'package:share_plus/share_plus.dart';
// gal import + descriptor import

Future<void> shareFile(File file, AttachmentDescriptor d) async {
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path, mimeType: d.mime, name: d.filename)]),
  );
}
```

(Confirm the `share_plus` v10 API surface against the installed version: `SharePlus.instance.share(ShareParams(...))`. If the resolved major differs, use that version's documented call.)

- [ ] **Step 3:** In `attachment_viewer.dart`, replace the inline `_saveToGallery` body with a call to `saveToGallery(widget.file, widget.descriptor)` (keep the `_saving`/toast UX wrapper), and add a Share `IconButton` (`Icons.ios_share`) to the AppBar `actions` calling `shareFile(widget.file, widget.descriptor)`.

- [ ] **Step 4:** `cd app && flutter analyze` + `flutter test`. Commit:

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/attachment/media_actions.dart app/lib/attachment/attachment_viewer.dart
git commit -m "feat(media): add share_plus, shared save/share helpers, viewer Share button (#56)"
```

---

### Task 7: Save/Share from the bubble long-press menu

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` (`_actions()` ~2865; the decrypt path used by `onOpenAttachment` ~1467)

**Interfaces:**
- Consumes: `saveToGallery`/`shareFile` (Task 6), the existing decrypt-to-file path behind `onOpenAttachment`.

- [ ] **Step 1:** Find the decrypt path `onOpenAttachment` runs (grep `onOpenAttachment` → it calls into `attachment_download`/`fetchAndDecrypt`). Factor a `Future<File> _ensureLocalFile(AttachmentDescriptor)` if one isn't already exposed.

- [ ] **Step 2:** In `_actions()`, for an image/video file bubble add two `_actionItem`s: "Save to Photos" (`Icons.download_rounded`) and "Share" (`Icons.ios_share`), gated on new `onSaveMedia`/`onShareMedia` callbacks wired only when `m.attachment` is image/video. Each callback: show a brief progress state, `final f = await _ensureLocalFile(att); await saveToGallery(f, att)` / `shareFile(f, att)`, then toast via the existing `showLoveToast`.

- [ ] **Step 3:** `cd app && flutter analyze` + `flutter test`. Commit:

```bash
git add app/lib/conversation/conversation_page.dart
git commit -m "feat(media): save/share actions in the bubble long-press menu (#56)"
```

---

### Task 8: Full verification + device build

- [ ] **Step 1:** `cd app && dart format . && flutter analyze && flutter test` — all green.
- [ ] **Step 2:** Build to a device (new `share_plus` plugin): `./scripts/ios-deploy.sh --server <dev-url> --device 0DC6E4DC-B58D-509A-A5B8-FD316A255D89`. Confirm: send a reply (swipe + menu), tap the quote jumps + highlights, edit a replied message keeps its quote, save + share a received photo and video from both the viewer and the bubble menu.
- [ ] **Step 3:** Commit any format-only changes; open the PR against `main` referencing #56.

## Self-Review

- **Spec coverage:** ReplyRef wire (T1) ✓; Msg/store + edit-preserve (T2) ✓; ingest + persistence (T3) ✓; send/outbox plumbing (T4) ✓; quote/jump/swipe/menu/chip (T5) ✓; share_plus + viewer (T6) ✓; bubble menu save/share (T7) ✓; verification incl. device build (T8) ✓. Save-already-exists is reused, not rebuilt ✓.
- **Placeholder scan:** UI tasks (T4/T5/T7) reference a few exact names to confirm by grep at execution (composer `onSend` callback name, `onOpenAttachment` decrypt fn, `share_plus` v10 API) — each is called out inline with how to resolve, not left as "TBD".
- **Type consistency:** `ReplyRef` fields (`id/author/kind/text`) and `Msg.replyTo` are used identically across T1-T7; `saveToGallery`/`shareFile` signatures match between T6 and T7.
