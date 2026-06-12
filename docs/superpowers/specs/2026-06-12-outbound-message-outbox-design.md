# Outbound Message Outbox — Design

**Issue:** [#11 — iOS app: sends silently dropped when WS is disconnected](https://github.com/CodingWithCourtReeves/little-love/issues/11)

## Problem

When the WebSocket is in a reconnecting/loading state and the user taps send,
the composer clears but the message never appears in the chat and never reaches
the server. No error UI, no snackbar. Two compounding bugs in
`app/lib/screens/inbox/inbox_shell.dart` and
`app/lib/conversation/conversation_page.dart`:

1. `ref.read(liveConnectionProvider).requireValue` throws when the provider
   isn't in `data` state.
2. The send is fire-and-forget from `_handleSubmit`, so the thrown future is
   silently swallowed.

Net result: data loss with zero feedback.

Underneath the bugs is a missing piece of architecture: there is no outbound
queue. Messages only exist in memory until the server echoes them back. This
spec adds a **persistent outbound outbox** that survives WS disconnects and app
crashes, with an optimistic local insert so the user sees their message
immediately.

## Design overview

```
                      ┌──────────────────────┐
   user taps send ───▶│  enqueue (sync)      │── insert into MessageStore
                      │  - encrypt           │   (optimistic, status=sending)
                      │  - INSERT outbox row │
                      │  - schedule drain    │
                      └──────────┬───────────┘
                                 │
                                 ▼
                      ┌──────────────────────┐
   WS reconnects ───▶ │  OutboxDrain         │── conn.send(SendFrame)
                      │  (singleton service) │   for each pending row
                      └──────────┬───────────┘
                                 │
                                 ▼
                      ┌──────────────────────┐
   server echo ─────▶ │  RoomMessageRouter   │── DELETE outbox row
                      │  ._ingestMessage     │   + promote optimistic Msg
                      └──────────────────────┘   to status=sent, real id
```

Plaintext is never written to disk. The ciphertext envelope is produced at
enqueue time and persisted as-is.

## Server changes (Rust)

### Echo `client_msg_id` on outgoing `Message` frames

Currently `server/src/ws.rs:198–204` discards `client_msg_id` (pattern
`client_msg_id: _`). Change it to thread the value through to `handle_send`,
which already broadcasts a `RoomServerFrame::Message`. Add `client_msg_id:
Option<Uuid>` to that variant.

- The field is optional on the wire (`Option<Uuid>`) so messages from peers
  who didn't author them are unaffected — only the sender's own echo carries
  the id.
- Server still uses its own `id: Uuid` as the authoritative server ID;
  `client_msg_id` is opaque metadata.
- Replay (`Subscribe.since_message_id`) does not need to preserve the
  `client_msg_id` — historical messages from past sessions are always treated
  as `sent`, and there is no outbox row to match.

### Tests

Add a `server/tests/rooms_routing.rs` assertion that a `Send` frame with a
known `client_msg_id` results in a `Message` frame that echoes the same id
back to the sender.

## Client changes (Flutter)

### New dependency

- `sqflite: ^2.x` (and transitively `sqflite_common_ffi` for desktop tests).
  The SQLite file lives at `<app_support_dir>/outbox.db`.

### Frame schema

`MessageFrame` gains `clientMsgId: String?`. JSON key is `client_msg_id`,
present only when the frame is echoing the sender's own message.

### `Msg` model

Add two fields:

```dart
final String? clientMsgId;
final SendStatus sendStatus; // sent | sending | failed
```

`SendStatus.sent` is the default for messages constructed from server frames.
Optimistic local inserts use `sending`. `failed` is only reached when the row
is unable to be sent for a non-retryable reason (encrypt error after the row
is already in the outbox — rare, but possible if key cache is invalidated).

### Outbox table

`outbox`:

| column          | type    | notes                                     |
| --------------- | ------- | ----------------------------------------- |
| `client_msg_id` | TEXT PK | UUID v4 generated at enqueue time         |
| `room_id`       | TEXT    | not null                                  |
| `body_cipher`   | TEXT    | base64 ciphertext envelope, not null      |
| `created_at`    | INTEGER | UTC millis since epoch, not null          |
| `attempts`      | INTEGER | not null, default 0                       |
| `last_error`    | TEXT    | nullable                                  |

Index on `created_at` for ordered drains.

### `OutboxStore`

A thin sqflite wrapper:

```dart
Future<void> enqueue({required String roomId, required String clientMsgId,
                      required String bodyCipher});
Future<List<OutboxRow>> pending(); // ORDER BY created_at ASC
Future<void> remove(String clientMsgId);
Future<void> markAttempt(String clientMsgId, {String? error});
```

Lives in `app/lib/outbox/outbox_store.dart`. Exposed as a Riverpod
`Provider<OutboxStore>`.

### Send path (`_handleSubmit` → `onSend`)

`onSend` becomes **synchronous from the composer's POV** — it returns
immediately so the composer clears without races:

```dart
void onSend(String text) {
  final clientMsgId = const Uuid().v4();
  unawaited(_enqueueAndDrain(roomId, clientMsgId, text)); // fire-and-forget OK
                                                          // because every
                                                          // failure path
                                                          // updates UI state
}

Future<void> _enqueueAndDrain(...) async {
  try {
    final me = await ref.read(currentIdentityProvider.future);
    final key = await ref.read(roomKeyCacheProvider).getOrDerive(room, me);
    final cipher = await encryptOutgoing(key, text);
    await outboxStore.enqueue(...);
    messageStore.add(Msg(
      id: clientMsgId,                // synthetic id; reconciled on echo
      clientMsgId: clientMsgId,
      from: me.username,
      to: roomId,
      body: text,
      ts: DateTime.now().toUtc(),
      sendStatus: SendStatus.sending,
    ));
    ref.read(outboxDrainProvider).kick();
  } catch (e) {
    // Encrypt or DB error before optimistic insert — show a snackbar.
    // No row in outbox; nothing to retry.
    _surfaceEnqueueFailure(e);
  }
}
```

`_handleSubmit` in `conversation_page.dart` keeps its current shape —
`widget.onSend(text); _controller.clear();` — but `onSend` is now safe to call
synchronously because the entry path doesn't throw on a bad WS state.

The `valueOrNull` / `requireValue` fix at `inbox_shell.dart:134` falls out
naturally: the send path no longer reads `liveConnectionProvider` at all.
That's now `OutboxDrain`'s responsibility.

### `OutboxDrain`

A Riverpod-owned singleton that:

1. **Watches `liveConnectionProvider`.** Whenever it transitions to `data`,
   call `kick()`.
2. `kick()` is idempotent — if a drain is already running it's a no-op.
3. The drain loop reads pending rows in `created_at` order and `conn.send`s
   each one, awaiting nothing because the WS write is fire-and-forget at the
   transport layer.
4. Per-row backoff: `delay = min(2^attempts seconds, 60s)`. If `attempts == 0`
   send immediately. After each send, increment `attempts` on the row but do
   not delete it — deletion happens on echo. (This means we may double-send if
   the server processed it before the connection dropped, but the receiver
   would dedup by server `id`.)
5. No max-retry cap. As long as the WS keeps reconnecting, the queue keeps
   draining.
6. If the WS drops mid-drain, the loop exits; the next `data` transition will
   restart it.

### Reconciliation (echo handling)

In `RoomMessageRouter._ingestMessage`:

```dart
if (frame.clientMsgId != null) {
  final removed = await outboxStore.remove(frame.clientMsgId!);
  if (removed) {
    messageStore.promote(
      fromId: frame.clientMsgId!,
      toMsg: Msg.fromFrame(frame, sendStatus: SendStatus.sent),
    );
    return;
  }
}
// fall through to existing add path (peer message, or replay of a message
// we authored on a previous device install)
messageStore.add(Msg.fromFrame(frame, sendStatus: SendStatus.sent));
```

`MessageStore.promote(fromId, toMsg)` replaces a row in-place by old id. If no
row matches (race or replay), it falls back to `add` so we never lose a
message.

### Failure UX

`ConversationPage._bubble` adds a caption slot beneath "mine" bubbles:

- `sent`: no caption.
- `sending`: muted `sending…` caption (TwilightColors.textMuted).
- `failed`: `failed · tap to retry` caption in a warning color. Add
  `TwilightColors.warningTone` (a desaturated red, ~`#B85C5C`) to the theme
  in the same change. Tapping the bubble calls
  `outboxStore.markAttempt(clientMsgId, error: null)` with `attempts = 0`
  and kicks the drain.

The caption slot is only rendered when `sendStatus != sent` — no layout shift
on transition.

No icons in v1 (per design review).

### Startup

`OutboxDrain` initialization is triggered the first time
`liveConnectionProvider` enters `data`. On app launch we:

1. Open the SQLite file.
2. **Re-hydrate optimistic messages from outbox into `MessageStore`.** For
   every pending row, await `currentIdentityProvider.future` and
   `roomKeyCacheProvider.getOrDerive(room, me)`, decrypt the ciphertext, and
   insert an in-memory `Msg(sendStatus: sending)`. Without this step, a user
   who killed the app while a message was queued would see the bubble vanish
   on next launch — only to have it reappear after the server echoes back the
   eventual send. Re-hydration keeps the UI consistent across crashes.
3. Trigger a drain after `liveConnectionProvider` enters `data`.

Re-hydration runs independently of the WS state — the user sees the
optimistic bubbles immediately, even before the connection is up.

If decryption fails for a row (lost key, corrupt envelope), mark it `failed`
and leave it in the outbox for manual retry/inspection. Do not silently drop.

## What this spec does NOT do

- **No server-side ack frame.** The `MessageFrame` echo IS the ack. A dedicated
  ack frame would be cleaner but is significantly more server scope.
- **No replay of full message history from local disk.** `MessageStore`
  remains in-memory for non-outbox messages. Persistence of the inbound side
  is its own future spec.
- **No SQLCipher.** The on-disk envelope is already ciphertext, and the
  device-level encryption on iOS/macOS (Data Protection, FileVault) covers
  the rest. Adding SQLCipher would mean another C dependency we don't need
  yet.
- **No delivery / read receipts.** Out of scope.
- **No group rooms considerations.** The current schema is 1:1; the outbox
  model maps cleanly to per-room rows when groups arrive.

## Testing

### Server
- New unit test: `Send` with `client_msg_id` X produces a `Message` frame
  with `client_msg_id` X echoed to the sender.

### Client
- `outbox_store_test.dart`: enqueue / pending order / remove / markAttempt.
- `outbox_drain_test.dart`: drain sends all pending rows in order; idempotent
  kick; resumes on simulated reconnect; respects exponential backoff using a
  `FakeAsync` clock.
- `conversation_page_outbox_test.dart`: tapping send while
  `liveConnectionProvider` is in `loading` state inserts an optimistic bubble
  with `sending…` caption; advancing to `data` and emitting an echo flips it
  to `sent` and removes the caption.
- `room_message_router_test.dart`: an incoming `MessageFrame` with a
  `clientMsgId` matching an outbox row promotes the optimistic message and
  deletes the row; an incoming `MessageFrame` without `clientMsgId` is added
  fresh.
- Reconciliation race: enqueue → echo arrives before drain completes →
  optimistic row is still promoted correctly.
- Encryption-at-enqueue: assert `body_cipher` column never equals plaintext
  in any test.

### Integration (manual smoke)
- Send → kill app mid-flight → relaunch → bubble re-appears as `sending…` →
  WS reconnects → bubble flips to `sent`.
- Send while in airplane mode → toggle airplane off → bubble flips to
  `sent` once WS reconnects.
- Force an encrypt failure (mocked) → bubble shows `failed · tap to retry`.

## Open questions

None at spec time. Anything that comes up during implementation goes back
through the plan / review loop.

## References

- [AsyncValue.requireValue — riverpod docs](https://pub.dev/documentation/riverpod/latest/riverpod/AsyncValue-class.html)
- [unawaited_futures — Dart linter](https://dart.dev/tools/linter-rules/unawaited_futures)
- [Signal `sentTimestamp`](https://github.com/signalapp/Signal-Android) — client-generated message id echoed on delivery
- [Matrix `txn_id`](https://spec.matrix.org/v1.10/client-server-api/#put_matrixclientv3roomsroomidsendeventtypetxnid) — client-chosen idempotency key for sends
- [sqflite](https://pub.dev/packages/sqflite)
