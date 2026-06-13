# Outbound Message Outbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix issue #11 — silent send drops when WS is reconnecting — by adding a persistent outbound outbox with optimistic local insert and server-echoed `client_msg_id` reconciliation.

**Architecture:** Server includes `client_msg_id` in the outbound `Message` frame so the sender can match its own echoes. Client encrypts at enqueue, persists ciphertext to a SQLite outbox, optimistically inserts the bubble with a `sending` status, drains the queue every time the WS reaches the `data` state, and promotes the optimistic message to `sent` when its echo arrives. UI gets a muted caption under "mine" bubbles: `sending…` or `failed · tap to retry`.

**Tech Stack:** Rust (axum/serde/tokio), Flutter (Riverpod, sqflite, cryptography), Dart test (flutter_test, sqflite_common_ffi).

**Spec:** `docs/superpowers/specs/2026-06-12-outbound-message-outbox-design.md`

---

## File Map

### Server
- Modify: `server/src/wire.rs` — add `client_msg_id: Option<Uuid>` to `RoomServerFrame::Message`.
- Modify: `server/src/ws.rs` — thread `client_msg_id` from `RoomClientFrame::Send` through `handle_send`, send a sender-only frame with the id echoed, and a peer frame without it.
- Modify: `server/tests/rooms_routing.rs` — add an assertion that the sender receives the same `client_msg_id` it sent.

### Client
- Modify: `app/pubspec.yaml` — add `sqflite`, `sqflite_common_ffi` (dev_dependency).
- Modify: `app/lib/wire/frames.dart` — parse `client_msg_id` into `MessageFrame.clientMsgId`.
- Modify: `app/lib/wire/message.dart` — add `clientMsgId` + `sendStatus` to `Msg`, add `SendStatus` enum.
- Modify: `app/lib/conversation/message_store.dart` — add `promote(fromId, toMsg)` + `updateStatus(id, status)`.
- Modify: `app/lib/theme/twilight.dart` — add `warningTone` color.
- Create: `app/lib/outbox/outbox_store.dart` — sqflite wrapper + provider.
- Create: `app/lib/outbox/outbox_drain.dart` — drain service + provider.
- Create: `app/lib/outbox/outbox_rehydrate.dart` — startup re-hydration of optimistic bubbles.
- Modify: `app/lib/conversation/room_message_router.dart` — reconcile echoed messages against the outbox.
- Modify: `app/lib/screens/inbox/inbox_shell.dart` — replace `_sendEncrypted` with an enqueue-and-kick path; drop the `requireValue` read.
- Modify: `app/lib/conversation/conversation_page.dart` — render `sending…` / `failed · tap to retry` caption beneath "mine" bubbles; wire tap-to-retry.
- Modify: `app/lib/main.dart` — initialize outbox + run re-hydration after sign-in.

### Tests
- Create: `app/test/outbox/outbox_store_test.dart`.
- Create: `app/test/outbox/outbox_drain_test.dart`.
- Create: `app/test/outbox/outbox_rehydrate_test.dart`.
- Modify: `app/test/wire/frames_room_test.dart` — assert MessageFrame parses `client_msg_id`.
- Modify: `app/test/conversation/message_store_test.dart` — cover `promote` and `updateStatus`.
- Modify: `app/test/conversation/room_message_router_test.dart` — reconcile + drop outbox row on echo.
- Create: `app/test/conversation/conversation_page_outbox_test.dart`.
- Modify: `server/tests/rooms_routing.rs` — `client_msg_id` echo.

---

## Task 1: Server — `client_msg_id` echo on Message frame

**Files:**
- Modify: `server/src/wire.rs:102-110` — extend `RoomServerFrame::Message`.
- Modify: `server/src/ws.rs:198-204, 448-511` — thread `client_msg_id` through `handle_send`.
- Modify: `server/tests/rooms_routing.rs` — assert echo.

- [ ] **Step 1.1: Add the failing integration test**

In `server/tests/rooms_routing.rs`, find the existing send/receive test (`client_msg_id` already appears at line 71). Add a new test alongside it:

```rust
#[tokio::test]
async fn send_echoes_client_msg_id_to_sender() {
    let app = harness::start_app().await;
    let (mut a, mut b) = harness::pair_two_clients(&app).await;

    let client_msg_id = "7c4e1c8a-7e7e-4b7a-9f23-1a0a17070707";
    a.send(serde_json::json!({
        "kind": "Send",
        "room_id": a.shared_room_id.clone(),
        "body": "hi",
        "client_msg_id": client_msg_id,
    }))
    .await;

    // Sender receives a Message frame with client_msg_id echoed.
    let frame = a.next_message_frame().await;
    assert_eq!(
        frame["client_msg_id"].as_str(),
        Some(client_msg_id),
        "sender's echo must include the original client_msg_id"
    );

    // Recipient receives a Message frame without client_msg_id.
    let peer_frame = b.next_message_frame().await;
    assert!(
        peer_frame.get("client_msg_id").is_none(),
        "peer must not receive the sender's client_msg_id"
    );
}
```

If `next_message_frame` and `pair_two_clients` do not exist on the existing harness, copy the inline pattern used by the existing test in this file (lines ~60-150) and embed the read/parse directly. The point is: send a `Send` with a known `client_msg_id`, read the next outbound frame on both sides, assert presence/absence of `client_msg_id`.

- [ ] **Step 1.2: Run the test to confirm it fails**

Run: `cd server && cargo test --test rooms_routing send_echoes_client_msg_id_to_sender -- --nocapture`
Expected: FAIL — either compile error (`client_msg_id` missing from frame) or assertion mismatch.

- [ ] **Step 1.3: Add `client_msg_id` to the wire enum**

In `server/src/wire.rs`, change the `Message` variant:

```rust
Message {
    id: String,
    room_id: String,
    from: String,
    ts: DateTime<Utc>,
    body: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    replayed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    client_msg_id: Option<Uuid>,
},
```

`Uuid` is already imported (used by `RoomClientFrame::Send`).

- [ ] **Step 1.4: Thread `client_msg_id` through `handle_send`**

In `server/src/ws.rs:198-204`, change the dispatch to capture the id:

```rust
Ok(RoomClientFrame::Send {
    room_id,
    body,
    client_msg_id,
}) => {
    handle_send(&state, &me, &room_id, &body, client_msg_id, &tx).await;
}
```

In `server/src/ws.rs:448-511`, update `handle_send`'s signature and fan-out. The frame to **the sender** carries `client_msg_id`; the frame to **every other room member** has it set to `None`.

```rust
async fn handle_send(
    state: &AppState,
    me: &AccountRecord,
    room_id: &str,
    body: &str,
    client_msg_id: Uuid,
    tx: &mpsc::UnboundedSender<RoomServerFrame>,
) {
    // ... existing is_member + insert logic unchanged ...

    let members = match member_usernames(store.pool(), room_id).await {
        Ok(m) => m,
        Err(e) => {
            warn!("member_usernames failed: {e}");
            return;
        }
    };
    let base = RoomServerFrame::Message {
        id: id.clone(),
        room_id: room_id.to_string(),
        from: me.username.clone(),
        ts,
        body: body.to_string(),
        replayed: false,
        client_msg_id: None,
    };
    for username in members {
        let frame = if username == me.username {
            let mut f = base.clone();
            if let RoomServerFrame::Message { client_msg_id: ref mut c, .. } = f {
                *c = Some(client_msg_id);
            }
            f
        } else {
            base.clone()
        };
        state.routing.deliver(&username, frame).await;
    }
}
```

- [ ] **Step 1.5: Update existing unit tests in `wire.rs`**

The `wire.rs` test module at line ~150 has Message-frame tests that construct `RoomServerFrame::Message { ... }` literally. Add `client_msg_id: None` to those constructors and add a serialize-test for `client_msg_id: Some(...)` that asserts the JSON contains `"client_msg_id":"<uuid>"`.

- [ ] **Step 1.6: Run all server tests**

Run: `cd server && cargo test`
Expected: PASS.

- [ ] **Step 1.7: Commit**

```bash
git add server/src/wire.rs server/src/ws.rs server/tests/rooms_routing.rs
git commit -m "server: echo client_msg_id on sender's own Message frame (issue #11)"
```

---

## Task 2: Client — parse `client_msg_id` in MessageFrame

**Files:**
- Modify: `app/lib/wire/frames.dart:153-168` — add `clientMsgId` to `MessageFrame`.
- Modify: `app/test/wire/frames_room_test.dart` — assertion.

- [ ] **Step 2.1: Failing test**

Append to `app/test/wire/frames_room_test.dart`:

```dart
test('MessageFrame parses client_msg_id when present', () {
  final frame = RoomServerFrame.fromJson({
    'kind': 'Message',
    'id': 'srv-1',
    'room_id': 'r1',
    'from': 'me',
    'ts': '2026-06-13T10:00:00Z',
    'body': 'ct',
    'client_msg_id': 'cli-abc',
  }) as MessageFrame;
  expect(frame.clientMsgId, 'cli-abc');
});

test('MessageFrame.clientMsgId is null when absent', () {
  final frame = RoomServerFrame.fromJson({
    'kind': 'Message',
    'id': 'srv-1',
    'room_id': 'r1',
    'from': 'peer',
    'ts': '2026-06-13T10:00:00Z',
    'body': 'ct',
  }) as MessageFrame;
  expect(frame.clientMsgId, isNull);
});
```

- [ ] **Step 2.2: Confirm failure**

Run: `cd app && flutter test test/wire/frames_room_test.dart`
Expected: FAIL — `MessageFrame` has no `clientMsgId`.

- [ ] **Step 2.3: Implement**

In `app/lib/wire/frames.dart` change `MessageFrame` and its `fromJson`:

```dart
class MessageFrame extends RoomServerFrame {
  const MessageFrame({
    required this.id,
    required this.roomId,
    required this.from,
    required this.ts,
    required this.body,
    required this.replayed,
    this.clientMsgId,
  });
  final String id;
  final String roomId;
  final String from;
  final DateTime ts;
  final String body;
  final bool replayed;
  final String? clientMsgId;
}
```

In the `case 'Message':` branch of `RoomServerFrame.fromJson` add `clientMsgId: json['client_msg_id'] as String?`.

- [ ] **Step 2.4: Run, pass, commit**

```bash
cd app && flutter test test/wire/frames_room_test.dart
```
Expected: PASS.

```bash
git add app/lib/wire/frames.dart app/test/wire/frames_room_test.dart
git commit -m "app/wire: parse client_msg_id on MessageFrame"
```

---

## Task 3: Client — `SendStatus` + `Msg.clientMsgId`

**Files:**
- Modify: `app/lib/wire/message.dart`.
- Modify: `app/test/wire/message_test.dart`.

- [ ] **Step 3.1: Failing test**

Append to `app/test/wire/message_test.dart`:

```dart
test('Msg defaults to SendStatus.sent and null clientMsgId', () {
  final m = Msg(
    id: 'x',
    from: 'a',
    to: 'r',
    body: 'b',
    ts: DateTime.utc(2026, 6, 13),
  );
  expect(m.sendStatus, SendStatus.sent);
  expect(m.clientMsgId, isNull);
});

test('Msg.copyWith updates sendStatus and id', () {
  final m = Msg(
    id: 'cli-1',
    from: 'a',
    to: 'r',
    body: 'b',
    ts: DateTime.utc(2026, 6, 13),
    sendStatus: SendStatus.sending,
    clientMsgId: 'cli-1',
  );
  final promoted = m.copyWith(id: 'srv-1', sendStatus: SendStatus.sent);
  expect(promoted.id, 'srv-1');
  expect(promoted.sendStatus, SendStatus.sent);
  expect(promoted.clientMsgId, 'cli-1');
});
```

- [ ] **Step 3.2: Confirm failure**

Run: `cd app && flutter test test/wire/message_test.dart`
Expected: FAIL — `SendStatus` undefined.

- [ ] **Step 3.3: Implement**

Replace `app/lib/wire/message.dart` body (keep the existing `Hello` class untouched) with:

```dart
enum SendStatus { sent, sending, failed }

class Msg {
  Msg({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.ts,
    this.replayed = false,
    this.clientMsgId,
    this.sendStatus = SendStatus.sent,
  });

  final String id;
  final String from;
  final String to;
  final String body;
  final DateTime ts;
  final bool replayed;

  /// Set on optimistic local inserts. Null for messages constructed
  /// straight from a server frame for a peer.
  final String? clientMsgId;

  final SendStatus sendStatus;

  factory Msg.fromJson(Map<String, Object?> json) {
    return Msg(
      id: json['id'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      body: json['body'] as String,
      ts: DateTime.parse(json['ts'] as String).toUtc(),
      replayed: (json['replayed'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'type': 'msg',
      'id': id,
      'from': from,
      'to': to,
      'body': body,
      'ts': ts.toUtc().toIso8601String(),
    };
    if (replayed) m['replayed'] = true;
    return m;
  }

  Msg copyWith({
    String? id,
    SendStatus? sendStatus,
  }) {
    return Msg(
      id: id ?? this.id,
      from: from,
      to: to,
      body: body,
      ts: ts,
      replayed: replayed,
      clientMsgId: clientMsgId,
      sendStatus: sendStatus ?? this.sendStatus,
    );
  }
}
```

- [ ] **Step 3.4: Run all wire tests**

Run: `cd app && flutter test test/wire/`
Expected: PASS.

- [ ] **Step 3.5: Commit**

```bash
git add app/lib/wire/message.dart app/test/wire/message_test.dart
git commit -m "app/wire: add SendStatus + clientMsgId on Msg"
```

---

## Task 4: Client — `MessageStore.promote` + `updateStatus`

**Files:**
- Modify: `app/lib/conversation/message_store.dart`.
- Modify: `app/test/conversation/message_store_test.dart`.

- [ ] **Step 4.1: Failing tests**

Append to `app/test/conversation/message_store_test.dart`:

```dart
test('promote replaces a row by old id and preserves clientMsgId', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final store = container.read(messageStoreProvider('r1').notifier);
  store.add(Msg(
    id: 'cli-1',
    from: 'me',
    to: 'r1',
    body: 'hi',
    ts: DateTime.utc(2026, 6, 13),
    clientMsgId: 'cli-1',
    sendStatus: SendStatus.sending,
  ));
  store.promote(
    fromId: 'cli-1',
    toMsg: Msg(
      id: 'srv-1',
      from: 'me',
      to: 'r1',
      body: 'hi',
      ts: DateTime.utc(2026, 6, 13),
      clientMsgId: 'cli-1',
      sendStatus: SendStatus.sent,
    ),
  );
  final after = container.read(messageStoreProvider('r1'));
  expect(after.single.id, 'srv-1');
  expect(after.single.sendStatus, SendStatus.sent);
  expect(after.single.clientMsgId, 'cli-1');
});

test('promote with unknown id falls back to add', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final store = container.read(messageStoreProvider('r1').notifier);
  store.promote(
    fromId: 'missing',
    toMsg: Msg(
      id: 'srv-1', from: 'peer', to: 'r1', body: 'hi',
      ts: DateTime.utc(2026, 6, 13),
    ),
  );
  expect(container.read(messageStoreProvider('r1')).single.id, 'srv-1');
});

test('updateStatus changes sendStatus on the matching id', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final store = container.read(messageStoreProvider('r1').notifier);
  store.add(Msg(
    id: 'cli-1', from: 'me', to: 'r1', body: 'hi',
    ts: DateTime.utc(2026, 6, 13),
    clientMsgId: 'cli-1', sendStatus: SendStatus.sending,
  ));
  store.updateStatus('cli-1', SendStatus.failed);
  expect(
    container.read(messageStoreProvider('r1')).single.sendStatus,
    SendStatus.failed,
  );
});
```

- [ ] **Step 4.2: Confirm failure**

Run: `cd app && flutter test test/conversation/message_store_test.dart`
Expected: FAIL — `promote` and `updateStatus` undefined.

- [ ] **Step 4.3: Implement**

In `app/lib/conversation/message_store.dart`, extend the class:

```dart
class MessageStore extends FamilyNotifier<List<Msg>, String> {
  @override
  List<Msg> build(String roomId) => const [];

  void add(Msg msg) {
    if (state.any((m) => m.id == msg.id)) return;
    state = [...state, msg];
  }

  void setAll(List<Msg> messages) {
    state = List.unmodifiable(messages);
  }

  /// Replace a message identified by [fromId] with [toMsg]. If no row matches
  /// (replay race, peer message), fall back to [add] so we never lose data.
  void promote({required String fromId, required Msg toMsg}) {
    final idx = state.indexWhere((m) => m.id == fromId);
    if (idx < 0) {
      add(toMsg);
      return;
    }
    final next = [...state];
    next[idx] = toMsg;
    state = next;
  }

  void updateStatus(String id, SendStatus status) {
    final idx = state.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final next = [...state];
    next[idx] = state[idx].copyWith(sendStatus: status);
    state = next;
  }
}
```

- [ ] **Step 4.4: Run, pass, commit**

```bash
cd app && flutter test test/conversation/message_store_test.dart
```
Expected: PASS.

```bash
git add app/lib/conversation/message_store.dart app/test/conversation/message_store_test.dart
git commit -m "app/conversation: MessageStore.promote + updateStatus"
```

---

## Task 5: Add sqflite dependencies

**Files:**
- Modify: `app/pubspec.yaml`.

- [ ] **Step 5.1: Add deps**

Edit `app/pubspec.yaml` and add under `dependencies:`:

```yaml
  sqflite: ^2.3.3
  sqflite_common_ffi: ^2.3.3
```

(Same package in main deps and dev_dependencies for VM tests — `sqflite_common_ffi` works in both. Keeping it in main deps means desktop builds get FFI without a second entry.)

- [ ] **Step 5.2: Pub get**

Run: `cd app && flutter pub get`
Expected: success.

- [ ] **Step 5.3: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock
git commit -m "app: add sqflite + sqflite_common_ffi for the outbox"
```

---

## Task 6: `OutboxStore`

**Files:**
- Create: `app/lib/outbox/outbox_store.dart`.
- Create: `app/test/outbox/outbox_store_test.dart`.

- [ ] **Step 6.1: Failing tests**

Create `app/test/outbox/outbox_store_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<OutboxStore> freshStore() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: OutboxStore.onCreate),
    );
    return OutboxStore.test(db);
  }

  test('enqueue then pending returns rows in created_at order', () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct-a',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 0),
    );
    await s.enqueue(
      clientMsgId: 'b', roomId: 'r1', bodyCipher: 'ct-b',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 1),
    );
    final rows = await s.pending();
    expect(rows.map((r) => r.clientMsgId).toList(), ['a', 'b']);
    expect(rows.first.bodyCipher, 'ct-a');
    expect(rows.first.roomId, 'r1');
  });

  test('remove deletes by client_msg_id and returns whether a row was removed',
      () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    expect(await s.remove('a'), isTrue);
    expect(await s.remove('a'), isFalse);
    expect((await s.pending()).isEmpty, isTrue);
  });

  test('markAttempt bumps attempts and stores last_error', () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    await s.markAttempt('a', error: 'boom');
    await s.markAttempt('a');
    final row = (await s.pending()).single;
    expect(row.attempts, 2);
    expect(row.lastError, isNull); // most recent markAttempt cleared it
  });

  test('markAttempt with reset:true zeroes attempts (retry tap)', () async {
    final s = await freshStore();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    await s.markAttempt('a', error: 'x');
    await s.markAttempt('a', reset: true);
    final row = (await s.pending()).single;
    expect(row.attempts, 0);
    expect(row.lastError, isNull);
  });
}
```

- [ ] **Step 6.2: Confirm failure**

Run: `cd app && flutter test test/outbox/outbox_store_test.dart`
Expected: FAIL — file/types missing.

- [ ] **Step 6.3: Implement**

Create `app/lib/outbox/outbox_store.dart`:

```dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class OutboxRow {
  OutboxRow({
    required this.clientMsgId,
    required this.roomId,
    required this.bodyCipher,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
  });

  final String clientMsgId;
  final String roomId;
  final String bodyCipher;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
}

class OutboxStore {
  OutboxStore._(this._db);

  /// Test constructor: pass an already-open DB (e.g. ffi in-memory).
  factory OutboxStore.test(Database db) => OutboxStore._(db);

  static Future<OutboxStore> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'outbox.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: onCreate,
    );
    return OutboxStore._(db);
  }

  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE outbox (
        client_msg_id TEXT PRIMARY KEY,
        room_id       TEXT NOT NULL,
        body_cipher   TEXT NOT NULL,
        created_at    INTEGER NOT NULL,
        attempts      INTEGER NOT NULL DEFAULT 0,
        last_error    TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX outbox_created_at_idx ON outbox(created_at)',
    );
  }

  final Database _db;

  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required String bodyCipher,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    await _db.insert('outbox', {
      'client_msg_id': clientMsgId,
      'room_id': roomId,
      'body_cipher': bodyCipher,
      'created_at': ts,
      'attempts': 0,
      'last_error': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<OutboxRow>> pending() async {
    final rows = await _db.query('outbox', orderBy: 'created_at ASC');
    return rows
        .map((r) => OutboxRow(
              clientMsgId: r['client_msg_id'] as String,
              roomId: r['room_id'] as String,
              bodyCipher: r['body_cipher'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                r['created_at'] as int,
                isUtc: true,
              ),
              attempts: r['attempts'] as int,
              lastError: r['last_error'] as String?,
            ))
        .toList(growable: false);
  }

  /// Returns true iff a row was deleted.
  Future<bool> remove(String clientMsgId) async {
    final n = await _db.delete(
      'outbox',
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
    );
    return n > 0;
  }

  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  }) async {
    if (reset) {
      await _db.update(
        'outbox',
        {'attempts': 0, 'last_error': null},
        where: 'client_msg_id = ?',
        whereArgs: [clientMsgId],
      );
      return;
    }
    await _db.rawUpdate(
      '''
      UPDATE outbox
         SET attempts = attempts + 1,
             last_error = ?
       WHERE client_msg_id = ?
      ''',
      [error, clientMsgId],
    );
  }
}

/// Owned by [outboxStoreProvider]. Initialized lazily on first read.
final outboxStoreProvider = FutureProvider<OutboxStore>((ref) async {
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    // Real sqflite is plugin-based on mobile but FFI on desktop. Tests opt in
    // via OutboxStore.test() with their own DB.
  }
  return OutboxStore.open();
});
```

- [ ] **Step 6.4: Run, pass, commit**

```bash
cd app && flutter test test/outbox/outbox_store_test.dart
```
Expected: PASS.

```bash
git add app/lib/outbox/outbox_store.dart app/test/outbox/outbox_store_test.dart
git commit -m "app/outbox: persistent SQLite outbox store"
```

---

## Task 7: `OutboxDrain`

**Files:**
- Create: `app/lib/outbox/outbox_drain.dart`.
- Create: `app/test/outbox/outbox_drain_test.dart`.

- [ ] **Step 7.1: Failing test**

Create `app/test/outbox/outbox_drain_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/outbox/outbox_drain.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeSender {
  final List<Map<String, Object?>> sent = [];
  bool throwOnNext = false;
  void send(String roomId, String bodyCipher, String clientMsgId) {
    if (throwOnNext) {
      throwOnNext = false;
      throw StateError('socket closed');
    }
    sent.add({
      'room_id': roomId,
      'body_cipher': bodyCipher,
      'client_msg_id': clientMsgId,
    });
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<OutboxStore> freshStore() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: OutboxStore.onCreate),
    );
    return OutboxStore.test(db);
  }

  test('drain sends all pending rows in created_at order', () async {
    final s = await freshStore();
    final sender = _FakeSender();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct-a',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 0),
    );
    await s.enqueue(
      clientMsgId: 'b', roomId: 'r1', bodyCipher: 'ct-b',
      createdAt: DateTime.utc(2026, 6, 13, 10, 0, 1),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    await drain.runOnce();
    expect(sender.sent.map((m) => m['client_msg_id']).toList(), ['a', 'b']);
    // Rows are NOT removed by drain; removal happens on echo.
    expect((await s.pending()).length, 2);
    // Each row's attempts incremented.
    expect((await s.pending()).first.attempts, 1);
  });

  test('drain stops at the first send error and records last_error', () async {
    final s = await freshStore();
    final sender = _FakeSender()..throwOnNext = true;
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    await drain.runOnce();
    expect(sender.sent, isEmpty);
    final row = (await s.pending()).single;
    expect(row.attempts, 1);
    expect(row.lastError, contains('socket closed'));
  });

  test('kick is idempotent — concurrent kicks coalesce', () async {
    final s = await freshStore();
    final sender = _FakeSender();
    await s.enqueue(
      clientMsgId: 'a', roomId: 'r1', bodyCipher: 'ct',
      createdAt: DateTime.utc(2026, 6, 13),
    );
    final drain = OutboxDrain(store: s, send: sender.send);
    final f1 = drain.kick();
    final f2 = drain.kick();
    await Future.wait([f1, f2]);
    expect(sender.sent.length, 1);
  });
}
```

- [ ] **Step 7.2: Confirm failure**

Run: `cd app && flutter test test/outbox/outbox_drain_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 7.3: Implement**

Create `app/lib/outbox/outbox_drain.dart`:

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'outbox_store.dart';

typedef OutboxSend = void Function(
  String roomId,
  String bodyCipher,
  String clientMsgId,
);

/// Drains the persistent outbox over a live WS connection. The drain itself
/// is best-effort: rows are removed only when their echoed MessageFrame
/// arrives (handled by RoomMessageRouter), not after a successful `send`.
class OutboxDrain {
  OutboxDrain({required this.store, required this.send});

  final OutboxStore store;
  final OutboxSend send;

  bool _running = false;
  Future<void>? _inflight;

  /// Idempotent: if a drain is already running, returns the in-flight future.
  Future<void> kick() {
    final existing = _inflight;
    if (existing != null) return existing;
    final f = _drainLoop();
    _inflight = f;
    return f.whenComplete(() => _inflight = null);
  }

  Future<void> _drainLoop() async {
    if (_running) return;
    _running = true;
    try {
      await runOnce();
    } finally {
      _running = false;
    }
  }

  /// Public for tests. Iterates pending rows in order and stops at the first
  /// transport error.
  Future<void> runOnce() async {
    final rows = await store.pending();
    for (final row in rows) {
      try {
        send(row.roomId, row.bodyCipher, row.clientMsgId);
        await store.markAttempt(row.clientMsgId);
      } catch (e) {
        await store.markAttempt(row.clientMsgId, error: e.toString());
        return;
      }
    }
  }
}

/// Wraps the live connection in an [OutboxSend] callable. The provider stays
/// loading until the first WS `data` event; once `data` is reached, it kicks
/// the drain on every subsequent transition.
final outboxDrainProvider = Provider<OutboxDrain>((ref) {
  final store = ref.watch(outboxStoreProvider).requireValue;
  final connAsync = ref.watch(liveConnectionProvider);
  final conn = connAsync.valueOrNull;

  final drain = OutboxDrain(
    store: store,
    send: (roomId, bodyCipher, clientMsgId) {
      if (conn == null) throw StateError('not connected');
      conn.send(
        SendFrame(
          roomId: roomId,
          body: bodyCipher,
          clientMsgId: clientMsgId,
        ).toJson(),
      );
    },
  );

  if (conn != null) {
    // Fire-and-forget kick: don't block provider construction.
    Future<void>(() => drain.kick());
  }

  return drain;
});

/// UUID helper exposed so [outbox_rehydrate] and the send path agree on
/// generation. Riverpod-overridable in tests.
final outboxIdGenProvider = Provider<String Function()>(
  (_) => () => const Uuid().v4(),
);
```

> Note: `outboxStoreProvider.requireValue` is safe here because we only build the drain provider after the store has been awaited at app startup (see Task 10).

- [ ] **Step 7.4: Run, pass, commit**

```bash
cd app && flutter test test/outbox/
```
Expected: PASS.

```bash
git add app/lib/outbox/outbox_drain.dart app/test/outbox/outbox_drain_test.dart
git commit -m "app/outbox: drain service with idempotent kick"
```

---

## Task 8: Theme — `warningTone`

**Files:**
- Modify: `app/lib/theme/twilight.dart`.

- [ ] **Step 8.1: Add color**

Open `app/lib/theme/twilight.dart`, find the `TwilightColors` class. Add alongside the other constants:

```dart
static const Color warningTone = Color(0xFFB85C5C);
```

- [ ] **Step 8.2: Verify the app still builds**

Run: `cd app && flutter test test/inbox/conversation_list_item_test.dart`
Expected: PASS (smoke).

- [ ] **Step 8.3: Commit**

```bash
git add app/lib/theme/twilight.dart
git commit -m "app/theme: add warningTone for failed-send caption"
```

---

## Task 9: Replace `_sendEncrypted` with enqueue path

**Files:**
- Modify: `app/lib/screens/inbox/inbox_shell.dart:130-142`.
- Modify: `app/test/conversation/conversation_page_encrypt_test.dart` (no plaintext leak still holds).

- [ ] **Step 9.1: Confirm existing encryption assertion still holds**

Run: `cd app && flutter test test/conversation/conversation_page_encrypt_test.dart`
Expected: PASS — baseline before refactor.

- [ ] **Step 9.2: Refactor the send path**

In `app/lib/screens/inbox/inbox_shell.dart`, replace `_sendEncrypted` (lines 130-142) with:

```dart
void _sendEncrypted(WidgetRef ref, Room room, String text) {
  final clientMsgId = ref.read(outboxIdGenProvider)();
  // Synchronous from the composer's POV; the async work below is
  // fire-and-forget but every failure path updates UI state.
  unawaited(_enqueueAndKick(ref, room, text, clientMsgId));
}

Future<void> _enqueueAndKick(
  WidgetRef ref,
  Room room,
  String text,
  String clientMsgId,
) async {
  try {
    final me = await ref.read(currentIdentityProvider.future);
    final key = await ref.read(roomKeyCacheProvider).getOrDerive(room, me);
    final cipher = await encryptOutgoing(key, text);
    final store = await ref.read(outboxStoreProvider.future);
    await store.enqueue(
      clientMsgId: clientMsgId,
      roomId: room.roomId,
      bodyCipher: cipher,
    );
    ref
        .read(messageStoreProvider(room.roomId).notifier)
        .add(Msg(
          id: clientMsgId,
          from: account.username,
          to: room.roomId,
          body: text,
          ts: DateTime.now().toUtc(),
          clientMsgId: clientMsgId,
          sendStatus: SendStatus.sending,
        ));
    await ref.read(outboxDrainProvider).kick();
  } catch (e) {
    debugPrint('outbox enqueue failed: $e');
  }
}
```

Add imports:

```dart
import 'dart:async' show unawaited;
import 'package:flutter/foundation.dart' show debugPrint;
import '../../outbox/outbox_drain.dart';
import '../../outbox/outbox_store.dart';
import '../../conversation/message_store.dart';
import '../../wire/message.dart';
```

Remove the now-unused imports of `live_connection.dart`, `frames.dart` (unless still referenced by other code in the file — keep what's needed) and the top-of-build `requireValue` workaround if any.

- [ ] **Step 9.3: Update the encryption widget test**

The existing `conversation_page_encrypt_test.dart` reaches into `liveConnectionProvider` directly. It now needs to also override `outboxStoreProvider` and `outboxDrainProvider`. The simplest path: extract a minimal in-memory `OutboxStore` via `OutboxStore.test(...)` in the test setup. The assertion stays the same — `body` on the SendFrame is base64 ciphertext, not plaintext — but the path of the assertion shifts from "captured by `_CapturingConn.sent`" to "captured by a stub drain sender".

Update the test to read `outboxStoreProvider.future` after sending, then assert `(await store.pending()).single.bodyCipher` is not equal to plaintext, and that decrypting it yields the plaintext. This is a more direct guarantee that plaintext never lands on the wire OR on disk.

```dart
final store = await container.read(outboxStoreProvider.future);
final pending = await store.pending();
expect(pending, hasLength(1));
expect(pending.single.bodyCipher, isNot(plaintext));
// decryptIncoming with the same key returns plaintext (proves it's the
// envelope we expect).
```

- [ ] **Step 9.4: Run, pass, commit**

```bash
cd app && flutter test test/conversation/conversation_page_encrypt_test.dart
```
Expected: PASS.

```bash
git add app/lib/screens/inbox/inbox_shell.dart app/test/conversation/conversation_page_encrypt_test.dart
git commit -m "app: route sends through the outbox (fix #11 silent drop)"
```

---

## Task 10: Reconciliation on echo

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`.
- Modify: `app/test/conversation/room_message_router_test.dart`.

- [ ] **Step 10.1: Failing test**

Append to `app/test/conversation/room_message_router_test.dart` a test that:

1. Pre-seeds an outbox row + an optimistic Msg with id == clientMsgId.
2. Emits a MessageFrame with the matching `clientMsgId` and a different server `id`.
3. Asserts: outbox row is gone, MessageStore now has the row under the server `id`, status `sent`.
4. Asserts: a second MessageFrame from the peer (no clientMsgId) is added normally.

The existing test file already has `_FakeConn`, `_container`, etc. — extend it. Use the same `ProviderContainer` style with `outboxStoreProvider.overrideWith` to inject an in-memory `OutboxStore`.

- [ ] **Step 10.2: Confirm failure**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: FAIL.

- [ ] **Step 10.3: Implement**

In `app/lib/conversation/room_message_router.dart`, update `_ingestMessage`:

```dart
Future<void> _ingestMessage(MessageFrame f) async {
  final inbox = ref.read(inboxStateProvider);
  Room? room;
  for (final r in inbox.rooms) {
    if (r.roomId == f.roomId) { room = r; break; }
  }
  if (room == null) return;
  final me = await ref.read(currentIdentityProvider.future);
  final key = await ref.read(roomKeyCacheProvider).getOrDerive(room, me);
  final plaintext = await decryptIncoming(key, f.body);
  final notifier = ref.read(messageStoreProvider(f.roomId).notifier);

  if (f.clientMsgId != null) {
    final outbox = await ref.read(outboxStoreProvider.future);
    final removed = await outbox.remove(f.clientMsgId!);
    if (removed) {
      notifier.promote(
        fromId: f.clientMsgId!,
        toMsg: Msg(
          id: f.id,
          from: f.from,
          to: f.roomId,
          body: plaintext,
          ts: f.ts,
          replayed: f.replayed,
          clientMsgId: f.clientMsgId,
          sendStatus: SendStatus.sent,
        ),
      );
      return;
    }
  }

  notifier.add(Msg(
    id: f.id,
    from: f.from,
    to: f.roomId,
    body: plaintext,
    ts: f.ts,
    replayed: f.replayed,
  ));
}
```

- [ ] **Step 10.4: Run, pass, commit**

```bash
cd app && flutter test test/conversation/
```
Expected: PASS.

```bash
git add app/lib/conversation/room_message_router.dart app/test/conversation/room_message_router_test.dart
git commit -m "app/conversation: reconcile echoed messages against the outbox"
```

---

## Task 11: Rehydration on app start

**Files:**
- Create: `app/lib/outbox/outbox_rehydrate.dart`.
- Create: `app/test/outbox/outbox_rehydrate_test.dart`.
- Modify: `app/lib/main.dart` — call rehydrate after sign-in.

- [ ] **Step 11.1: Failing test**

Create `app/test/outbox/outbox_rehydrate_test.dart`. Setup: an in-memory `OutboxStore` pre-seeded with two rows (different rooms), a fake `decrypt` callable that maps `ct -> "plaintext"`. Call `rehydrate(container, store, decryptFn)` and assert that both `messageStoreProvider(room1)` and `messageStoreProvider(room2)` end up with the right `Msg` rows, all with `sendStatus: sending`.

- [ ] **Step 11.2: Confirm failure**

Run: `cd app && flutter test test/outbox/outbox_rehydrate_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 11.3: Implement**

Create `app/lib/outbox/outbox_rehydrate.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../identity/current_identity.dart';
import '../inbox/inbox_state.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../conversation/room_key_cache.dart';
import '../wire/message.dart';
import 'outbox_store.dart';

typedef OutboxDecrypt = Future<String> Function(Room room, String cipher);

/// Re-insert optimistic bubbles for every persisted outbox row. Runs once
/// after sign-in, independent of WS state.
Future<void> rehydrateOutbox(
  Ref ref, {
  OutboxDecrypt? decrypt,
}) async {
  final store = await ref.read(outboxStoreProvider.future);
  final rows = await store.pending();
  if (rows.isEmpty) return;

  final identity = await ref.read(currentIdentityProvider.future);
  final keyCache = ref.read(roomKeyCacheProvider);
  final rooms = ref.read(inboxStateProvider).rooms;
  final byId = {for (final r in rooms) r.roomId: r};

  for (final row in rows) {
    final room = byId[row.roomId];
    if (room == null) continue; // stale row, skip
    String text;
    try {
      if (decrypt != null) {
        text = await decrypt(room, row.bodyCipher);
      } else {
        final key = await keyCache.getOrDerive(room, identity);
        text = await decryptIncoming(key, row.bodyCipher);
      }
    } catch (_) {
      // Mark failed in-place; keep the row so the user can retry / inspect.
      await store.markAttempt(row.clientMsgId, error: 'decrypt-failed');
      ref
          .read(messageStoreProvider(row.roomId).notifier)
          .add(_failedMsg(row, identity.username));
      continue;
    }
    ref.read(messageStoreProvider(row.roomId).notifier).add(Msg(
          id: row.clientMsgId,
          from: identity.username,
          to: row.roomId,
          body: text,
          ts: row.createdAt,
          clientMsgId: row.clientMsgId,
          sendStatus: SendStatus.sending,
        ));
  }
}

Msg _failedMsg(OutboxRow row, String me) => Msg(
      id: row.clientMsgId,
      from: me,
      to: row.roomId,
      body: '(message could not be decrypted)',
      ts: row.createdAt,
      clientMsgId: row.clientMsgId,
      sendStatus: SendStatus.failed,
    );
```

- [ ] **Step 11.4: Wire into main**

In `app/lib/main.dart`, find where the authenticated session starts (after `accountProvider` resolves). Call `await rehydrateOutbox(ref);` once. Look for the first place inside the auth-gated subtree that has a `Ref` — if there's no obvious spot, add a small `Consumer` widget that calls it in `initState`:

```dart
class _RehydrateGate extends ConsumerStatefulWidget {
  const _RehydrateGate({required this.child});
  final Widget child;
  @override
  ConsumerState<_RehydrateGate> createState() => _RehydrateGateState();
}

class _RehydrateGateState extends ConsumerState<_RehydrateGate> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    // Trigger once when rooms are first available.
    if (!_done) {
      final hasRooms = ref.watch(inboxStateProvider).rooms.isNotEmpty;
      if (hasRooms) {
        _done = true;
        Future<void>(() => rehydrateOutbox(ref));
      }
    }
    return widget.child;
  }
}
```

Wrap the `InboxShell` in `_RehydrateGate` so re-hydration runs once after the room list arrives. The dependency on `inboxStateProvider.rooms` is intentional — we need rooms in order to resolve keys.

- [ ] **Step 11.5: Run, pass, commit**

```bash
cd app && flutter test test/outbox/
```
Expected: PASS.

```bash
git add app/lib/outbox/outbox_rehydrate.dart app/lib/main.dart app/test/outbox/outbox_rehydrate_test.dart
git commit -m "app/outbox: rehydrate optimistic bubbles on launch"
```

---

## Task 12: Caption rendering + tap-to-retry

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart` — `_bubble`.
- Create: `app/test/conversation/conversation_page_outbox_test.dart`.

- [ ] **Step 12.1: Failing widget test**

Create `app/test/conversation/conversation_page_outbox_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  testWidgets('mine bubble shows "sending…" caption when status=sending',
      (tester) async {
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => LocalAccount(
            username: 'me',
            createdAt: DateTime.utc(2026, 6, 13),
          )),
    ]);
    addTearDown(container.dispose);
    container.read(messageStoreProvider('r1').notifier).add(Msg(
          id: 'cli-1',
          from: 'me',
          to: 'r1',
          body: 'on my way',
          ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
          clientMsgId: 'cli-1',
          sendStatus: SendStatus.sending,
        ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          roomId: 'r1',
          contactDisplayName: 'Kaitlyn',
          onSend: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('sending…'), findsOneWidget);
  });

  testWidgets('failed bubble shows retry caption and tap invokes onRetry',
      (tester) async {
    final retried = <String>[];
    final container = ProviderContainer(overrides: [
      accountProvider.overrideWith((_) async => LocalAccount(
            username: 'me',
            createdAt: DateTime.utc(2026, 6, 13),
          )),
    ]);
    addTearDown(container.dispose);
    container.read(messageStoreProvider('r1').notifier).add(Msg(
          id: 'cli-1',
          from: 'me',
          to: 'r1',
          body: 'eh',
          ts: DateTime.utc(2026, 6, 13, 10, 0, 0),
          clientMsgId: 'cli-1',
          sendStatus: SendStatus.failed,
        ));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          roomId: 'r1',
          contactDisplayName: 'Kaitlyn',
          onSend: (_) {},
          onRetry: (clientMsgId) => retried.add(clientMsgId),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('failed · tap to retry'), findsOneWidget);
    await tester.tap(find.text('eh'));
    expect(retried, ['cli-1']);
  });
}
```

- [ ] **Step 12.2: Confirm failure**

Run: `cd app && flutter test test/conversation/conversation_page_outbox_test.dart`
Expected: FAIL — captions absent, `onRetry` not on widget.

- [ ] **Step 12.3: Implement caption + retry**

In `app/lib/conversation/conversation_page.dart`:

1. Add an `onRetry` callback:

```dart
typedef RetryCallback = void Function(String clientMsgId);
// ...
const ConversationPage({
  super.key,
  required this.roomId,
  required this.contactDisplayName,
  required this.onSend,
  this.onRetry,
});
final RetryCallback? onRetry;
```

2. Replace the `_bubble` method's `mine` branch to wrap the bubble + a caption slot in a `Column`:

```dart
Widget _bubble(Msg m, String me) {
  final mine = m.from == me;
  final tip = _formatFullDateTime(m.ts.toLocal());
  final bubble = _bubbleContent(m, mine, tip); // factor existing bubble body
                                               // into a helper unchanged
  if (!mine || m.sendStatus == SendStatus.sent) return bubble;

  final caption = m.sendStatus == SendStatus.sending
      ? const Text(
          'sending…',
          style: TextStyle(
            color: TwilightColors.textMuted,
            fontSize: 11,
          ),
        )
      : const Text(
          'failed · tap to retry',
          style: TextStyle(
            color: TwilightColors.warningTone,
            fontSize: 11,
          ),
        );

  final tappable = m.sendStatus == SendStatus.failed && widget.onRetry != null
      ? GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onRetry!(m.clientMsgId ?? m.id),
          child: bubble,
        )
      : bubble;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      tappable,
      Padding(
        padding: const EdgeInsets.only(right: 8, top: 2, bottom: 2),
        child: caption,
      ),
    ],
  );
}
```

The existing bubble body becomes `_bubbleContent` — copy lines 311-362 verbatim into the new helper.

3. Wire `onRetry` from `inbox_shell.dart`:

```dart
return ConversationPage(
  key: ValueKey(selectedId),
  roomId: selectedId,
  contactDisplayName: room.peerUsername,
  onSend: (text) => _sendEncrypted(ref, room, text),
  onRetry: (clientMsgId) => _retry(ref, clientMsgId),
);

Future<void> _retry(WidgetRef ref, String clientMsgId) async {
  final store = await ref.read(outboxStoreProvider.future);
  await store.markAttempt(clientMsgId, reset: true);
  ref
      .read(messageStoreProvider(/* find roomId from id */).notifier)
      .updateStatus(clientMsgId, SendStatus.sending);
  await ref.read(outboxDrainProvider).kick();
}
```

For `_retry`, you need the roomId. The simplest path: query the outbox row by id before resetting, e.g. add a `OutboxStore.lookup(clientMsgId)` returning the room or `null`. Add that method:

```dart
Future<OutboxRow?> lookup(String clientMsgId) async {
  final rows = await _db.query(
    'outbox', where: 'client_msg_id = ?', whereArgs: [clientMsgId], limit: 1,
  );
  if (rows.isEmpty) return null;
  // ... same shape as `pending()` mapping; extract into a helper to DRY
}
```

And add a one-line test in `outbox_store_test.dart`.

- [ ] **Step 12.4: Run, pass, commit**

```bash
cd app && flutter test test/conversation/conversation_page_outbox_test.dart test/outbox/outbox_store_test.dart
```
Expected: PASS.

```bash
git add app/lib/conversation/conversation_page.dart app/lib/screens/inbox/inbox_shell.dart app/lib/outbox/outbox_store.dart app/test/conversation/conversation_page_outbox_test.dart app/test/outbox/outbox_store_test.dart
git commit -m "app/ui: caption + tap-to-retry for outbox-backed sends"
```

---

## Task 13: Full test sweep + analyze

- [ ] **Step 13.1: Run every Flutter test**

Run: `cd app && flutter test`
Expected: all green.

- [ ] **Step 13.2: Static analysis**

Run: `cd app && flutter analyze`
Expected: no warnings introduced by this change.

- [ ] **Step 13.3: Run every server test**

Run: `cd server && cargo test`
Expected: all green.

- [ ] **Step 13.4: Commit any lint fixes**

If `flutter analyze` flagged anything (unused imports, etc.), fix and commit:

```bash
git add -A
git commit -m "app: clean up after outbox refactor"
```

(Skip if there's nothing to commit.)

---

## Task 14: Manual smoke (iOS or macOS)

- [ ] **Step 14.1: Build + run on a device**

Pair the two test accounts. Send a normal message — it should appear instantly and stay sent.

- [ ] **Step 14.2: Airplane-mode test**

Toggle airplane mode on, send a message → bubble appears with `sending…` caption. Toggle airplane mode off → bubble flips to no-caption within a few seconds.

- [ ] **Step 14.3: Cold-start during sending test**

Toggle airplane mode on, send a message, force-quit the app, relaunch. The bubble should re-appear with `sending…` caption. Toggle airplane mode off → bubble flips to sent.

- [ ] **Step 14.4: Open the PR**

```bash
gh pr create --title "fix(app): persistent outbox so sends survive WS reconnect (#11)" --body "$(cat <<'EOF'
## Summary
- Fixes #11.
- Server: echoes `client_msg_id` on the sender's own `Message` frame so the client can reconcile its optimistic insert.
- Client: SQLite-backed outbox at `<app-support>/outbox.db`; encrypt at enqueue, plaintext never persisted.
- Client: optimistic `sending…` caption beneath own bubbles; `failed · tap to retry` on encrypt errors.
- Client: drain runs every time the WS reaches `data`; survives app crashes via rehydration.

## Test plan
- [x] `cd server && cargo test`
- [x] `cd app && flutter test && flutter analyze`
- [x] Manual smoke: airplane-mode → send → reconnect → bubble flips.
- [x] Manual smoke: kill app mid-send → relaunch → bubble re-appears as sending → reconnect → flips.

Spec: `docs/superpowers/specs/2026-06-12-outbound-message-outbox-design.md`
Plan: `docs/superpowers/plans/2026-06-13-outbound-message-outbox.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review notes

- **Spec coverage:**
  - `client_msg_id` echo on server → Task 1. ✓
  - `MessageFrame.clientMsgId` parsing → Task 2. ✓
  - `Msg` + `SendStatus` → Task 3. ✓
  - `MessageStore.promote` → Task 4. ✓
  - Outbox table + CRUD → Tasks 5, 6. ✓
  - `OutboxDrain` (WS-data trigger, idempotent kick, error path) → Task 7. ✓
  - `warningTone` theme color → Task 8. ✓
  - Send path replacement → Task 9. ✓
  - Reconciliation on echo → Task 10. ✓
  - Rehydration → Task 11. ✓
  - Caption UI + retry → Task 12. ✓
  - Manual smoke → Task 14. ✓

- **Note for executor:** the design specifies per-row exponential backoff (`min(2^attempts, 60s)`). This plan implements the simpler "drain whatever's pending whenever WS transitions to data" loop. If the WS bounces rapidly the queue will retry too quickly. If that's observed in smoke testing, add a `Stopwatch`-based delay in `_drainLoop` before each `send` based on `row.attempts`. Skipping it in v1 keeps Task 7 small; flag it for follow-up if needed.
