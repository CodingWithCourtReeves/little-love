# Message Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add message-text search — within a channel and globally across rooms — backed by a new local encrypted (SQLCipher) message store that persists decrypted history on-device.

**Architecture:** A new `MessageDb` (SQLCipher) is an idempotent, rebuildable projection of the server's ciphertext stream, written through at the existing `RoomMessageRouter` ingestion choke-points while `MessageStore` stays a pure in-memory Notifier. On room open, the store hydrates from the DB and the WebSocket subscribes from a per-room high-water-mark (delta sync). An FTS5 virtual table over message text powers BM25+recency-ranked search on two surfaces: the channel-info page and the chat-rooms list.

**Tech Stack:** Flutter + Riverpod, `sqflite_sqlcipher` (new), `sqflite_common_ffi` (existing test dep), `flutter_secure_storage` (existing), SQLite FTS5. Rust/Postgres server is **unchanged**.

## Global Constraints

- **No server changes for the MVP.** The server already replays full history on `SubscribeFrame(sinceMessageId: null)`; it stores/routes opaque ciphertext only.
- **No data statements in server migrations** (N/A here — no server migrations).
- **The local DB is a rebuildable projection**, never the system of record. Decrypted plaintext is reproducible from `server ciphertext + room key`.
- **`MessageStore` stays pure & synchronous.** All DB I/O lives in `MessageDb` and is awaited at the router (which is already async). Do not add async/DB calls inside `MessageStore` methods.
- **DB key:** per-device 32-byte random key in the keychain via `flutter_secure_storage` with `KeychainAccessibility.first_unlock_this_device`. Never synced, never escrowed.
- **Tokenizer:** FTS5 `unicode61` with `remove_diacritics=2`. Trigram/substring is out of scope.
- **iOS-only MVP.** Verify the `sqflite_sqlcipher` native plugin with an on-device build (a green `flutter test` does NOT prove iOS compiles — CLAUDE.md federated-plugin caveat). Deploy to Court's iPhone 17 Pro Max (`0DC6E4DC-B58D-509A-A5B8-FD316A255D89`) and the iPhone 13 Pro Max (`F031FD6D-9E3D-5005-918D-BB860CE37C26`), one at a time via `ios-deploy.sh`. Never Kaitlyn's.
- **Never run `cargo test` against the dev DB.** (No Rust changes expected.)
- **Commit messages** end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

**Create:**
- `app/lib/conversation/message_db.dart` — `MessageDb` abstraction + `SqliteMessageDb` (SQLCipher) impl + `messageDbProvider`. Owns schema, projection writes, HWM, and (Milestone 2) FTS search.
- `app/lib/conversation/message_db_key.dart` — keychain-backed DB key mint/load.
- `app/lib/conversation/message_search.dart` — search result model + search providers.
- `app/lib/conversation/message_search_page.dart` — in-channel search UI.
- `app/lib/inbox/global_search_page.dart` — global (cross-room) search UI.
- Tests mirroring each under `app/test/...`.

**Modify:**
- `app/pubspec.yaml` — add `sqflite_sqlcipher`.
- `app/lib/conversation/room_message_router.dart` — write-through at choke-points; HWM delta subscribe; hydrate-on-open.
- `app/lib/conversation/message_store.dart` — add a `hydrate`/`setAll` entry usable by the router (uses existing `setAll`).
- `app/lib/conversation/chat_info_page.dart` — wire the stubbed 🔍 to push `MessageSearchPage`.
- `app/lib/conversation/conversation_page.dart` — optional `focusMessageId` + scroll-to-message + highlight; load-older-from-DB.
- `app/lib/screens/inbox/home_screen.dart` — global search entry point.
- `app/lib/identity/...` sign-out path — clear `MessageDb` (mirrors `outbox.clear()`).

---

# MILESTONE 1 — Local encrypted store + sync

*Deliverable: decrypted history persists across app restarts, hydrates instantly on open, and reconnect pulls only the delta. Independently valuable and testable.*

---

## Task 1: `MessageDb` abstraction + SQLCipher impl + `messages` schema

**Files:**
- Create: `app/lib/conversation/message_db.dart`
- Create: `app/lib/conversation/message_db_key.dart`
- Modify: `app/pubspec.yaml`
- Test: `app/test/conversation/message_db_test.dart`

**Interfaces:**
- Produces:
  - `abstract class MessageDb` with `static Future<MessageDb> open()`, `factory MessageDb.test(Database db)`, and methods (filled across Tasks 1–2 & 7):
    - `Future<void> upsert(Msg msg, {required String roomId})`
    - `Future<List<Msg>> messagesFor(String roomId)`
    - `Future<void> reconcile(String clientMsgId, Msg server)`
    - `Future<void> applyDelete(String targetId, {required String requestedBy})`
    - `Future<void> applyReaction(String targetId, String username, String emoji)`
    - `Future<void> markRead(List<String> ids)`
    - `Future<String?> highWaterMark(String roomId)`
    - `Future<void> clear()`
    - `Future<List<SearchHit>> search(String query, {String? roomId, int limit})` (Task 7)
  - `final messageDbProvider = FutureProvider<MessageDb>((ref) => MessageDb.open());`

- [ ] **Step 1: Add the dependency**

In `app/pubspec.yaml`, under `dependencies:`, add (keep alphabetical with the other `sqflite*` entry):

```yaml
  sqflite_sqlcipher: ^3.1.0
```

Run: `cd app && flutter pub get`
Expected: `Got dependencies!`

- [ ] **Step 2: Write the DB-key helper**

Create `app/lib/conversation/message_db_key.dart`:

```dart
import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mints (once) and loads the per-device SQLCipher key for the local message
/// store. The key never leaves the device: stored in the iOS keychain with
/// `first_unlock_this_device`, never synced or escrowed. The DB it protects is
/// a rebuildable projection of the server's ciphertext, so losing the key (e.g.
/// keychain wipe) is recoverable — the store re-seeds from a full replay.
class MessageDbKey {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _name = 'llove.msgdb.key';

  /// Returns the base64 key, minting a fresh 32-byte random key on first use.
  static Future<String> loadOrCreate() async {
    final existing = await _storage.read(key: _name);
    if (existing != null) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = base64.encode(bytes);
    await _storage.write(key: _name, value: key);
    return key;
  }
}
```

- [ ] **Step 3: Write the failing test**

Create `app/test/conversation/message_db_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  sqfliteFfiInit();

  Future<MessageDb> freshDb() async {
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    return MessageDb.test(db);
  }

  Msg msg(String id, {String body = 'hello', String from = 'alice'}) => Msg(
        id: id,
        from: from,
        to: 'room1',
        body: body,
        ts: DateTime.utc(2026, 6, 24, 12, 0, int.parse(id.replaceAll(RegExp('[^0-9]'), '0'))),
      );

  test('upsert then read back, ordered by id ascending', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'first'), roomId: 'room1');
    await db.upsert(msg('01B', body: 'second'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.map((m) => m.body), ['first', 'second']);
  });

  test('upsert is idempotent on id', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'v1'), roomId: 'room1');
    await db.upsert(msg('01A', body: 'v2'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.length, 1);
  });

  test('messagesFor scopes by room', () async {
    final db = await freshDb();
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room2');
    expect((await db.messagesFor('room1')).length, 1);
    expect((await db.messagesFor('room2')).length, 1);
  });
}
```

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: FAIL — `message_db.dart` / `MessageDb` not defined.

- [ ] **Step 4: Implement `MessageDb` (Task-1 surface)**

Create `app/lib/conversation/message_db.dart`:

```dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../attachment/attachment_descriptor.dart';
import '../wire/message.dart';
import 'message_db_key.dart';

/// Local, SQLCipher-encrypted projection of the server's message stream.
///
/// This is a **rebuildable cache**, never the source of truth: decrypted
/// plaintext is reproducible from the server's ciphertext + the room key. All
/// writes are idempotent upserts keyed by the server message id, mirroring the
/// invariants in [MessageStore] (tombstones, optimistic reconcile, out-of-order
/// read receipts). Mirrors the [OutboxStore] shape: an abstract surface, a
/// SQLCipher-backed production impl, and a `.test` factory that wraps a plain
/// ffi [Database] so unit tests skip the native crypto layer.
abstract class MessageDb {
  static const schemaVersion = 1;

  static Future<MessageDb> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'messages.db');
    final key = await MessageDbKey.loadOrCreate();
    final db = await openDatabase(
      path,
      password: key,
      version: schemaVersion,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    );
    return SqliteMessageDb(db);
  }

  factory MessageDb.test(Database db) = SqliteMessageDb;

  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id            TEXT NOT NULL,
        room_id       TEXT NOT NULL,
        from_user     TEXT NOT NULL,
        body          TEXT NOT NULL,
        ts            INTEGER NOT NULL,
        send_status   INTEGER NOT NULL,
        client_msg_id TEXT,
        attachment    TEXT,
        link_preview  TEXT,
        call_outcome  TEXT,
        reactions     TEXT NOT NULL DEFAULT '{}',
        deleted       INTEGER NOT NULL DEFAULT 0,
        deleted_by    TEXT,
        PRIMARY KEY (id)
      )
    ''');
    await db.execute('CREATE INDEX messages_room_id_idx ON messages(room_id, id)');
    // Per-room high-water-mark (max stored server ULID) for delta sync.
    await db.execute('''
      CREATE TABLE room_sync (
        room_id TEXT PRIMARY KEY,
        hwm     TEXT NOT NULL
      )
    ''');
    // Tombstones survive restarts so an out-of-order delete still suppresses a
    // later-arriving target (mirrors MessageStore._deleted).
    await db.execute('''
      CREATE TABLE tombstones (
        target_id    TEXT PRIMARY KEY,
        requested_by TEXT NOT NULL
      )
    ''');
  }

  static Future<void> onUpgrade(Database db, int oldV, int newV) async {
    // Additive migrations land here as the schema evolves. The store is a
    // rebuildable projection, so a gnarly change may instead bump
    // `schemaVersion`, DROP the affected tables here, and let the next connect
    // re-seed from a full replay.
  }

  Future<void> upsert(Msg msg, {required String roomId});
  Future<List<Msg>> messagesFor(String roomId);
}

class SqliteMessageDb implements MessageDb {
  SqliteMessageDb(this._db);
  final Database _db;

  @override
  Future<void> upsert(Msg msg, {required String roomId}) async {
    // A validly-tombstoned id never re-enters the projection.
    final tomb = await _db.query('tombstones',
        where: 'target_id = ?', whereArgs: [msg.id], limit: 1);
    if (tomb.isNotEmpty && tomb.first['requested_by'] == msg.from) return;
    await _db.insert('messages', _toRow(msg, roomId),
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await _advanceHwm(roomId, msg.id);
  }

  @override
  Future<List<Msg>> messagesFor(String roomId) async {
    final rows = await _db.query('messages',
        where: 'room_id = ? AND deleted = 0', whereArgs: [roomId], orderBy: 'id ASC');
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<void> _advanceHwm(String roomId, String id) async {
    await _db.rawInsert(
      'INSERT INTO room_sync(room_id, hwm) VALUES(?, ?) '
      'ON CONFLICT(room_id) DO UPDATE SET hwm = excluded.hwm '
      'WHERE excluded.hwm > room_sync.hwm',
      [roomId, id],
    );
  }

  Map<String, Object?> _toRow(Msg m, String roomId) => {
        'id': m.id,
        'room_id': roomId,
        'from_user': m.from,
        'body': m.body,
        'ts': m.ts.toUtc().millisecondsSinceEpoch,
        'send_status': m.sendStatus.index,
        'client_msg_id': m.clientMsgId,
        'attachment': m.attachment == null ? null : jsonEncode(m.attachment!.toJson()),
        'link_preview': m.linkPreview == null ? null : jsonEncode(m.linkPreview!.toJson()),
        'call_outcome': m.callOutcome,
        'reactions': jsonEncode(m.reactions),
        'deleted': 0,
      };

  Msg _fromRow(Map<String, Object?> r) => Msg(
        id: r['id'] as String,
        from: r['from_user'] as String,
        to: r['room_id'] as String,
        body: r['body'] as String,
        ts: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int, isUtc: true),
        replayed: true,
        clientMsgId: r['client_msg_id'] as String?,
        sendStatus: SendStatus.values[r['send_status'] as int],
        attachment: r['attachment'] == null
            ? null
            : AttachmentDescriptor.fromJson(
                jsonDecode(r['attachment'] as String) as Map<String, Object?>),
        linkPreview: r['link_preview'] == null
            ? null
            : LinkPreview.fromJson(
                jsonDecode(r['link_preview'] as String) as Map<String, Object?>),
        callOutcome: r['call_outcome'] as String?,
        reactions: (jsonDecode(r['reactions'] as String) as Map<String, Object?>)
            .map((k, v) => MapEntry(k, v as String)),
      );
}

/// Opened lazily on first read; overridable in tests with [MessageDb.test].
final messageDbProvider = FutureProvider<MessageDb>((ref) => MessageDb.open());
```

> **Note:** confirm `AttachmentDescriptor.toJson/fromJson` and `LinkPreview.toJson/fromJson` exist; both already serialize for the wire, so reuse those. Add the `LinkPreview` import to the file. If a serializer is missing, add a minimal one in its own file as part of this task.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/conversation/message_db.dart app/lib/conversation/message_db_key.dart app/test/conversation/message_db_test.dart
git commit -m "feat(messages): local SQLCipher message store (schema + upsert)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Projection operations — reconcile, delete, reaction, read, HWM

**Files:**
- Modify: `app/lib/conversation/message_db.dart`
- Test: `app/test/conversation/message_db_test.dart`

**Interfaces:**
- Consumes: `MessageDb` from Task 1.
- Produces: `reconcile`, `applyDelete`, `applyReaction`, `markRead`, `highWaterMark`, `clear` (signatures listed in Task 1 interfaces). Semantics mirror `MessageStore` exactly.

- [ ] **Step 1: Write the failing tests**

Append to `app/test/conversation/message_db_test.dart`:

```dart
  test('reconcile swaps the optimistic row for the server id, keeping clientMsgId', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(id: 'cmid-1', from: 'alice', to: 'room1', body: 'hi', ts: DateTime.utc(2026), clientMsgId: 'cmid-1', sendStatus: SendStatus.sending),
      roomId: 'room1',
    );
    await db.reconcile('cmid-1', Msg(id: '01SERVER', from: 'alice', to: 'room1', body: 'hi', ts: DateTime.utc(2026)));
    final rows = await db.messagesFor('room1');
    expect(rows.single.id, '01SERVER');
    expect(rows.single.clientMsgId, 'cmid-1');
  });

  test('applyDelete soft-deletes and stays sticky for an out-of-order target', () async {
    final db = await freshDb();
    // Delete arrives first (target not yet stored).
    await db.applyDelete('01X', requestedBy: 'alice');
    // Target arrives later, authored by alice — must stay suppressed.
    await db.upsert(Msg(id: '01X', from: 'alice', to: 'room1', body: 'gone', ts: DateTime.utc(2026)), roomId: 'room1');
    expect(await db.messagesFor('room1'), isEmpty);
  });

  test('applyDelete rejects a spoofed delete (requestedBy != author)', () async {
    final db = await freshDb();
    await db.upsert(Msg(id: '01Y', from: 'alice', to: 'room1', body: 'mine', ts: DateTime.utc(2026)), roomId: 'room1');
    await db.applyDelete('01Y', requestedBy: 'bob'); // bob can't unsend alice's msg
    expect((await db.messagesFor('room1')).length, 1);
  });

  test('markRead promotes send_status to read', () async {
    final db = await freshDb();
    await db.upsert(Msg(id: '01Z', from: 'me', to: 'room1', body: 'seen?', ts: DateTime.utc(2026)), roomId: 'room1');
    await db.markRead(['01Z']);
    expect((await db.messagesFor('room1')).single.sendStatus, SendStatus.read);
  });

  test('applyReaction stores and toggles off', () async {
    final db = await freshDb();
    await db.upsert(Msg(id: '01R', from: 'alice', to: 'room1', body: 'react me', ts: DateTime.utc(2026)), roomId: 'room1');
    await db.applyReaction('01R', 'bob', '❤️');
    expect((await db.messagesFor('room1')).single.reactions, {'bob': '❤️'});
    await db.applyReaction('01R', 'bob', '');
    expect((await db.messagesFor('room1')).single.reactions, isEmpty);
  });

  test('highWaterMark returns the max stored id per room, null when empty', () async {
    final db = await freshDb();
    expect(await db.highWaterMark('room1'), isNull);
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01C'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room1');
    expect(await db.highWaterMark('room1'), '01C');
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: FAIL — methods not defined.

- [ ] **Step 3: Implement the operations**

Add to `abstract class MessageDb` the method declarations, and to `SqliteMessageDb`:

```dart
  @override
  Future<void> reconcile(String clientMsgId, Msg server) async {
    final tomb = await _db.query('tombstones',
        where: 'target_id = ?', whereArgs: [server.id], limit: 1);
    if (tomb.isNotEmpty && tomb.first['requested_by'] == server.from) {
      await _db.delete('messages', where: 'id = ?', whereArgs: [clientMsgId]);
      return;
    }
    // Idempotent: if the server id already exists, just drop the optimistic row.
    final existing = await _db.query('messages',
        where: 'id = ?', whereArgs: [server.id], limit: 1);
    final n = await _db.update(
      'messages',
      {..._toRow(server, server.to), 'client_msg_id': clientMsgId},
      where: 'id = ?',
      whereArgs: [clientMsgId],
    );
    if (n == 0 && existing.isEmpty) {
      await upsert(server.copyWith(clientMsgId: clientMsgId), roomId: server.to);
    } else if (existing.isNotEmpty) {
      await _db.delete('messages', where: 'id = ?', whereArgs: [clientMsgId]);
    } else {
      await _advanceHwm(server.to, server.id);
    }
  }

  @override
  Future<void> applyDelete(String targetId, {required String requestedBy}) async {
    final row = await _db.query('messages',
        where: 'id = ?', whereArgs: [targetId], limit: 1);
    if (row.isNotEmpty && row.first['from_user'] != requestedBy) return; // spoofed
    await _db.insert('tombstones',
        {'target_id': targetId, 'requested_by': requestedBy},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _db.update('messages', {'deleted': 1, 'deleted_by': requestedBy},
        where: 'id = ?', whereArgs: [targetId]);
  }

  @override
  Future<void> applyReaction(String targetId, String username, String emoji) async {
    final row = await _db.query('messages',
        where: 'id = ?', whereArgs: [targetId], limit: 1);
    if (row.isEmpty) return;
    final reactions = (jsonDecode(row.first['reactions'] as String) as Map<String, Object?>)
        .map((k, v) => MapEntry(k, v as String));
    if (emoji.isEmpty) {
      reactions.remove(username);
    } else {
      reactions[username] = emoji;
    }
    await _db.update('messages', {'reactions': jsonEncode(reactions)},
        where: 'id = ?', whereArgs: [targetId]);
  }

  @override
  Future<void> markRead(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE messages SET send_status = ${SendStatus.read.index} WHERE id IN ($placeholders)',
      ids,
    );
  }

  @override
  Future<String?> highWaterMark(String roomId) async {
    final rows = await _db.query('room_sync',
        columns: ['hwm'], where: 'room_id = ?', whereArgs: [roomId], limit: 1);
    return rows.isEmpty ? null : rows.first['hwm'] as String;
  }

  @override
  Future<void> clear() async {
    await _db.delete('messages');
    await _db.delete('room_sync');
    await _db.delete('tombstones');
  }
```

> **Note:** `markRead` deliberately does not store a separate "read but not-yet-arrived" set — the server replays a message before its read receipt on reconnect, and live receipts arrive after the row is upserted. If an on-device test shows a receipt landing first, add a `read_pending` table mirroring `MessageStore._read` and re-apply it in `upsert`.

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/message_db_test.dart`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/message_db.dart app/test/conversation/message_db_test.dart
git commit -m "feat(messages): projection ops — reconcile/delete/reaction/read/HWM

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Write-through at the router choke-points

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`
- Test: `app/test/conversation/room_message_router_test.dart` (existing — extend)

**Interfaces:**
- Consumes: `messageDbProvider`, `MessageDb` ops from Tasks 1–2.
- Produces: every ingestion mutation also persists to `MessageDb`.

- [ ] **Step 1: Write the failing test**

Open `app/test/conversation/room_message_router_test.dart`, find the existing harness (it overrides `outboxStoreProvider` with an ffi/in-memory store). Add an in-memory `MessageDb` override using the same ffi pattern as `message_db_test.dart`'s `freshDb()`, exposed to assertions. Then add:

```dart
  test('an ingested partner message is persisted to MessageDb', () async {
    // ... arrange router with overridden messageDbProvider (ffi) ...
    // ... feed a MessageFrame for room1 from the partner ...
    final persisted = await messageDb.messagesFor('room1');
    expect(persisted.map((m) => m.body), contains('hello from partner'));
  });

  test('an inbound delete soft-deletes in MessageDb', () async {
    // ... ingest a message, then a DeleteContent frame for its id ...
    expect(await messageDb.messagesFor('room1'), isEmpty);
  });
```

> Match the existing file's arrangement helpers; reuse its `ProviderContainer`/override setup rather than re-inventing it.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: FAIL — DB empty (no write-through yet).

- [ ] **Step 3: Implement write-through**

In `room_message_router.dart`, resolve the DB once near the top of `_ingestMessage` (after `final store = ...`):

```dart
    final db = await ref.read(messageDbProvider.future);
```

Then, alongside each store mutation:

- Reaction branch (after `store.applyReaction(...)`, line ~257):
  ```dart
      await db.applyReaction(content.targetId, f.from, content.emoji);
  ```
- Delete branch (after `store.applyDelete(...)`, line ~270):
  ```dart
      await db.applyDelete(content.targetId, requestedBy: f.from);
  ```
- Reconcile branch (after `store.reconcile(...)`, line ~335):
  ```dart
      await db.reconcile(f.clientMsgId!, msg);
  ```
- Add branch (after `store.add(msg)`, line ~342):
  ```dart
      await db.upsert(msg, roomId: f.roomId);
  ```

And for read receipts, in `_onFrame`'s `ReadFrame` case (line ~100):

```dart
      case ReadFrame(:final roomId, :final messageIds):
        ref.read(messageStoreProvider(roomId).notifier).markRead(messageIds);
        unawaited(_persistRead(roomId, messageIds));
```

Add a helper:

```dart
  Future<void> _persistRead(String roomId, List<String> ids) async {
    final db = await ref.read(messageDbProvider.future);
    await db.markRead(ids);
  }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: PASS (new + all pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/room_message_router.dart app/test/conversation/room_message_router_test.dart
git commit -m "feat(messages): write-through ingestion to MessageDb

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Hydrate-on-open + HWM delta-sync subscribe

**Files:**
- Modify: `app/lib/conversation/room_message_router.dart`
- Test: `app/test/conversation/room_message_router_test.dart`

**Interfaces:**
- Consumes: `MessageDb.messagesFor`, `MessageDb.highWaterMark`; `MessageStore.setAll`.
- Produces: on first subscribe to a room, the store is hydrated from the DB and the `SubscribeFrame` carries `sinceMessageId = HWM` (null on first run → full seed).

- [ ] **Step 1: Write the failing test**

Add to `room_message_router_test.dart`:

```dart
  test('subscribe hydrates the store from MessageDb and sends HWM as sinceMessageId', () async {
    // Pre-seed messageDb with two rows for room1 (ids 01A, 01B).
    await messageDb.upsert(/* 01A */, roomId: 'room1');
    await messageDb.upsert(/* 01B */, roomId: 'room1');
    // Deliver a RoomsFrame containing room1 → triggers _subscribe.
    // ...
    // Store is hydrated:
    expect(container.read(messageStoreProvider('room1')).map((m) => m.id), ['01A', '01B']);
    // Subscribe frame carried the HWM:
    expect(sentFrames.whereType<SubscribeFrame>().last.sinceMessageId, '01B');
  });
```

> Use the test's existing fake `LiveConnection` to capture sent frames (`sentFrames`). If none exists, add a capturing fake mirroring the production `LiveConnection` interface.

- [ ] **Step 2: Run to verify failure**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: FAIL — store not hydrated; `sinceMessageId` is null.

- [ ] **Step 3: Implement hydrate + HWM subscribe**

Change `_subscribe` to async and hydrate first:

```dart
  Future<void> _subscribe(String roomId) async {
    if (!_subscribed.add(roomId)) return;
    final db = await ref.read(messageDbProvider.future);
    final cached = await db.messagesFor(roomId);
    if (cached.isNotEmpty) {
      ref.read(messageStoreProvider(roomId).notifier).setAll(cached);
    }
    final hwm = await db.highWaterMark(roomId);
    conn.send(SubscribeFrame(roomId: roomId, sinceMessageId: hwm).toJson());
  }
```

Update the two call sites (`RoomsFrame` loop, `_upsertRoom` paths) to `unawaited(_subscribe(...))` or `await` as the surrounding context allows (the `RoomsFrame` loop is inside the async `_onFrame`; `await` each).

> **Ordering invariant:** hydrate (and thus `setAll`) MUST complete before the `SubscribeFrame` is sent, so server replay frames land on top of the hydrated buffer rather than racing it. The sequential `await`s above guarantee this on our side; the server doesn't replay until it receives the Subscribe.

- [ ] **Step 4: Run to verify pass**

Run: `cd app && flutter test test/conversation/room_message_router_test.dart`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `cd app && flutter test`
Expected: PASS (all, incl. the original 427).

```bash
git add app/lib/conversation/room_message_router.dart app/test/conversation/room_message_router_test.dart
git commit -m "feat(messages): hydrate-on-open + HWM delta-sync subscribe

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Clear the store on sign-out

**Files:**
- Modify: the sign-out path that already calls `outbox.clear()` (grep: `outbox` + `clear` / sign-out handler under `app/lib/identity/` or `app/lib/screens/auth/`)
- Test: alongside the existing sign-out test if present.

**Interfaces:**
- Consumes: `MessageDb.clear`.

- [ ] **Step 1: Locate the sign-out cleanup**

Run: `cd app && grep -rn "outbox" lib --include=*.dart | grep -i "clear\|signout\|sign_out\|logout"`
Expected: the handler that wipes per-account local state on sign-out.

- [ ] **Step 2: Write/extend the failing test**

In the same test that asserts `outbox.clear()` on sign-out, assert the message DB is cleared too:

```dart
  test('sign-out clears the local message store', () async {
    await messageDb.upsert(/* a row */, roomId: 'room1');
    await signOut(container); // however the existing test triggers it
    expect(await messageDb.messagesFor('room1'), isEmpty);
  });
```

- [ ] **Step 3: Run to verify failure**

Run the targeted test. Expected: FAIL — rows remain.

- [ ] **Step 4: Implement**

In the sign-out handler, next to the existing `outbox.clear()`:

```dart
    final messageDb = await ref.read(messageDbProvider.future);
    await messageDb.clear();
```

- [ ] **Step 5: Run + commit**

Run the targeted test then `cd app && flutter test`. Expected: PASS.

```bash
git add -A
git commit -m "feat(messages): clear local store on sign-out

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Milestone-1 on-device verification (REQUIRED)

**No code.** A green `flutter test` does not prove the SQLCipher plugin compiles for iOS.

- [ ] **Step 1: Full local CI gate**

Run: `cd app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test`
Expected: clean format, no analyzer issues, all tests pass.

- [ ] **Step 2: Build + install to Court's iPhone 17 Pro Max**

Run: `./scripts/ios-deploy.sh --server <dev-url> --device 0DC6E4DC-B58D-509A-A5B8-FD316A255D89`
Expected: "App installed". An **unchanged `databaseUUID`** confirms no forced re-signup.

- [ ] **Step 3: Build + install to the iPhone 13 Pro Max** (after step 2 finishes — never two release builds in parallel)

Run: `./scripts/ios-deploy.sh --server <dev-url> --device F031FD6D-9E3D-5005-918D-BB860CE37C26`

- [ ] **Step 4: Manual checks on-device**

- Send/receive a few messages between the two phones.
- **Force-quit and relaunch** → history is present immediately (offline-capable), without a full re-replay flash.
- Unsend a message on one phone → it stays gone after relaunch on both.
- Confirm a double-heart read receipt survives relaunch.

- [ ] **Step 5: Commit a short verification note** (optional) to the plan or a NOTES file recording the `databaseUUID` was unchanged.

**▢ MILESTONE 1 COMPLETE — persistent local history shipped. Proceed to search.**

---

# MILESTONE 2 — Search

*Deliverable: ranked, highlighted message search on the channel-info page and the chat-rooms list, with tap-to-jump.*

---

## Task 7: FTS5 index + ranked `search()`

**Files:**
- Modify: `app/lib/conversation/message_db.dart` (schema + triggers + `search`)
- Create: `app/lib/conversation/message_search.dart` (`SearchHit` model)
- Test: `app/test/conversation/message_search_test.dart`

**Interfaces:**
- Produces:
  - `class SearchHit { final String messageId; final String roomId; final String from; final DateTime ts; final String snippetHtml; final String body; }`
  - `Future<List<SearchHit>> MessageDb.search(String query, {String? roomId, int limit = 50})`

- [ ] **Step 1: Add the FTS schema (bump version)**

In `message_db.dart` set `schemaVersion = 2`. In `onCreate`, after the `messages` table, add:

```dart
    await db.execute('''
      CREATE VIRTUAL TABLE messages_fts USING fts5(
        body,
        content='messages',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');
    // Keep FTS in lockstep with the content table. A soft-deleted row is removed
    // from the index via the UPDATE trigger (deleted=1 → we delete the fts row).
    await db.execute('''
      CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
        INSERT INTO messages_fts(rowid, body)
          SELECT new.rowid, new.body WHERE new.deleted = 0;
      END
    ''');
```

In `onUpgrade`, handle the 1→2 jump by creating the FTS table + triggers and back-filling from existing rows:

```dart
    if (oldV < 2) {
      // Create messages_fts + triggers (same DDL as onCreate), then:
      await db.execute(
        "INSERT INTO messages_fts(rowid, body) SELECT rowid, body FROM messages WHERE deleted = 0");
    }
```

> Add a `rowid`-friendly note: `messages` uses `id TEXT PRIMARY KEY`, so SQLite keeps an implicit `rowid` — `content_rowid='rowid'` is correct.

- [ ] **Step 2: Write the failing test**

Create `app/test/conversation/message_search_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  sqfliteFfiInit();
  Future<MessageDb> freshDb() async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: MessageDb.schemaVersion,
            onCreate: MessageDb.onCreate,
            onUpgrade: MessageDb.onUpgrade));
    return MessageDb.test(db);
  }

  Msg m(String id, String body, {String room = 'room1'}) =>
      Msg(id: id, from: 'alice', to: room, body: body, ts: DateTime.utc(2026, 1, 1).add(Duration(minutes: id.codeUnitAt(id.length - 1))));

  test('prefix match finds partial words', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'I love you'), roomId: 'room1');
    final hits = await db.search('lov');
    expect(hits.map((h) => h.messageId), contains('01A'));
  });

  test('accent-insensitive', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'café tonight'), roomId: 'room1');
    expect((await db.search('cafe')).length, 1);
  });

  test('roomId scopes the search', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'shared word', room: 'room1'), roomId: 'room1');
    await db.upsert(m('01B', 'shared word', room: 'room2'), roomId: 'room2');
    expect((await db.search('shared', roomId: 'room1')).length, 1);
    expect((await db.search('shared')).length, 2); // global
  });

  test('soft-deleted messages drop out of the index', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'secret plan'), roomId: 'room1');
    await db.applyDelete('01A', requestedBy: 'alice');
    expect(await db.search('secret'), isEmpty);
  });

  test('snippet wraps matches in <b> tags', () async {
    final db = await freshDb();
    await db.upsert(m('01A', 'happy birthday darling'), roomId: 'room1');
    final hit = (await db.search('birthday')).single;
    expect(hit.snippetHtml, contains('<b>birthday</b>'));
  });
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd app && flutter test test/conversation/message_search_test.dart`
Expected: FAIL — `search` / `SearchHit` not defined.

- [ ] **Step 4: Implement `SearchHit` + `search`**

Create `app/lib/conversation/message_search.dart`:

```dart
class SearchHit {
  const SearchHit({
    required this.messageId,
    required this.roomId,
    required this.from,
    required this.ts,
    required this.snippetHtml,
    required this.body,
  });

  final String messageId;
  final String roomId;
  final String from;
  final DateTime ts;

  /// Body with matches wrapped in `<b>…</b>` (from FTS5 `snippet()`), for the
  /// result-row highlight.
  final String snippetHtml;
  final String body;
}
```

Add `search` to `MessageDb`/`SqliteMessageDb` (`import 'message_search.dart';`):

```dart
  @override
  Future<List<SearchHit>> search(String query, {String? roomId, int limit = 50}) async {
    final match = _toPrefixMatch(query);
    if (match.isEmpty) return const [];
    // bm25() is negative (most-relevant most-negative). Blend with a mild
    // recency boost: newer ts nudges the score more negative. Order ascending.
    final where = StringBuffer('messages_fts MATCH ? AND m.deleted = 0');
    final args = <Object?>[match];
    if (roomId != null) {
      where.write(' AND m.room_id = ?');
      args.add(roomId);
    }
    args.add(limit);
    final rows = await _db.rawQuery('''
      SELECT m.id, m.room_id, m.from_user, m.ts, m.body,
             snippet(messages_fts, 0, '<b>', '</b>', '…', 12) AS snip,
             bm25(messages_fts) - (m.ts / 1.0e15) AS score
      FROM messages_fts
      JOIN messages m ON m.rowid = messages_fts.rowid
      WHERE ${where.toString()}
      ORDER BY score ASC
      LIMIT ?
    ''', args);
    return rows
        .map((r) => SearchHit(
              messageId: r['id'] as String,
              roomId: r['room_id'] as String,
              from: r['from_user'] as String,
              ts: DateTime.fromMillisecondsSinceEpoch(r['ts'] as int, isUtc: true),
              snippetHtml: r['snip'] as String,
              body: r['body'] as String,
            ))
        .toList(growable: false);
  }

  /// Turn user text into a safe FTS5 prefix query: split on whitespace, strip
  /// FTS operators, and append `*` to each token for as-you-type matching.
  static String _toPrefixMatch(String query) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))
        .where((t) => t.isNotEmpty)
        .map((t) => '"$t"*');
    return tokens.join(' ');
  }
```

> The `m.ts / 1.0e15` term is a deliberately gentle recency nudge (ts is epoch-ms ≈ 1.7e12, so the term ≈ 0.0017) — enough to break ties toward recent messages without overpowering BM25. Tune on-device if needed.

- [ ] **Step 5: Run to verify pass**

Run: `cd app && flutter test test/conversation/message_search_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/message_db.dart app/lib/conversation/message_search.dart app/test/conversation/message_search_test.dart
git commit -m "feat(search): FTS5 index + BM25/recency ranked search()

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Search providers

**Files:**
- Modify: `app/lib/conversation/message_search.dart`
- Test: `app/test/conversation/message_search_provider_test.dart`

**Interfaces:**
- Produces:
  - `final channelSearchProvider = FutureProvider.family<List<SearchHit>, ({String roomId, String query})>(...)`
  - `final globalSearchProvider = FutureProvider.family<List<SearchHit>, String>(...)`

- [ ] **Step 1: Write the failing test**

Create `app/test/conversation/message_search_provider_test.dart` — override `messageDbProvider` with an ffi DB seeded with rows, then:

```dart
  test('channelSearchProvider returns scoped hits; empty query → empty', () async {
    expect(await container.read(channelSearchProvider((roomId: 'room1', query: '')).future), isEmpty);
    final hits = await container.read(channelSearchProvider((roomId: 'room1', query: 'love')).future);
    expect(hits, isNotEmpty);
  });
```

- [ ] **Step 2: Run to verify failure** — `cd app && flutter test test/conversation/message_search_provider_test.dart` → FAIL.

- [ ] **Step 3: Implement** (in `message_search.dart`):

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'message_db.dart';

final channelSearchProvider =
    FutureProvider.family<List<SearchHit>, ({String roomId, String query})>((ref, a) async {
  if (a.query.trim().isEmpty) return const [];
  final db = await ref.watch(messageDbProvider.future);
  return db.search(a.query, roomId: a.roomId);
});

final globalSearchProvider =
    FutureProvider.family<List<SearchHit>, String>((ref, query) async {
  if (query.trim().isEmpty) return const [];
  final db = await ref.watch(messageDbProvider.future);
  return db.search(query);
});
```

- [ ] **Step 4: Run to verify pass** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/message_search.dart app/test/conversation/message_search_provider_test.dart
git commit -m "feat(search): channel + global search providers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: In-channel search page + wire the stub

**Files:**
- Create: `app/lib/conversation/message_search_page.dart`
- Modify: `app/lib/conversation/chat_info_page.dart:219` (the `chat-info-search` action)
- Test: `app/test/conversation/message_search_page_test.dart`

**Interfaces:**
- Consumes: `channelSearchProvider`, `SearchHit`.
- Produces: `MessageSearchPage` returning the tapped `SearchHit`'s `messageId` via `Navigator.pop`, and a `route({required Room room, required String selfUsername})`.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/conversation/message_search_page_test.dart`: pump `MessageSearchPage` with an overridden `messageDbProvider` seeded with a matching message; enter text into the search field (`Key('message-search-field')`); expect a result tile showing the snippet; tap it; expect the page pops with the message id.

- [ ] **Step 2: Run to verify failure** → FAIL (page not defined).

- [ ] **Step 3: Implement the page**

Create `app/lib/conversation/message_search_page.dart` — a `ConsumerStatefulWidget` with a `TextField(key: Key('message-search-field'))` in the AppBar, a debounced query `StateProvider`/local controller, and a `ListView` of results built from `ref.watch(channelSearchProvider((roomId: room.roomId, query: query)))`. Render each hit with a `RichText` that bolds the `<b>…</b>` spans from `snippetHtml` (small parser: split on the tags) and the sender + relative time. `onTap: () => Navigator.of(context).pop(hit.messageId)`. Follow `chat_info_page.dart` palette/style conventions (`context.palette`).

- [ ] **Step 4: Wire the stub button**

In `chat_info_page.dart`, change the search action (line 219) to pass an `onTap`:

```dart
        _action(
          context,
          'chat-info-search',
          Icons.search,
          'Search',
          'Search',
          onTap: () async {
            final messageId = await Navigator.of(context).push<String>(
              MessageSearchPage.route(room: room, selfUsername: selfUsername),
            );
            if (messageId == null) return;
            // Hop back to the conversation focused on the result (Task 10 reads
            // this). The conversation is below this page on the stack.
            if (context.mounted) Navigator.of(context).pop(messageId);
          },
        ),
```

Add `import 'message_search_page.dart';`. (The conversation page, which pushed `ChatInfoPage`, receives the popped `messageId` and focuses it — wired in Task 10.)

- [ ] **Step 5: Run to verify pass** — `cd app && flutter test test/conversation/message_search_page_test.dart` → PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/conversation/message_search_page.dart app/lib/conversation/chat_info_page.dart app/test/conversation/message_search_page_test.dart
git commit -m "feat(search): in-channel search page wired to chat-info 🔍

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Scroll-to-message + highlight

**Files:**
- Modify: `app/lib/conversation/conversation_page.dart`
- Test: `app/test/conversation/conversation_scroll_test.dart`

**Interfaces:**
- Consumes: `MessageDb.messagesFor` (to load older rows if the target predates the in-memory window), the `messageId` popped from `ChatInfoPage`/`MessageSearchPage`.
- Produces: conversation scrolls to and briefly highlights a target message.

- [ ] **Step 1: Write the failing test**

Create `app/test/conversation/conversation_scroll_test.dart`: pump `ConversationPage` with a store of N messages, drive `focusMessage(targetId)`, and assert the target row becomes visible (its `Key('msg-<id>')` is found in the viewport) and gets the highlight decoration (a `Key('msg-highlight-<id>')` or color flag).

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement**

In `conversation_page.dart`:
1. Where it handles the `ChatInfoPage` push result (search the file for `ChatInfoPage.route`), capture the returned id and call a new `_focusMessage(id)`:
   ```dart
   final focusId = await Navigator.of(context).push<String>(ChatInfoPage.route(...));
   if (focusId != null) _focusMessage(focusId);
   ```
2. Add `_focusMessage`:
   ```dart
   Future<void> _focusMessage(String messageId) async {
     // Ensure the target is in the buffer; if it predates the loaded window,
     // hydrate the full room history from the local DB first.
     var idx = _items.indexWhere((it) => it is _BubbleItem && it.msg.id == messageId);
     if (idx < 0) {
       final db = await ref.read(messageDbProvider.future);
       final all = await db.messagesFor(widget.room.roomId);
       ref.read(messageStoreProvider(widget.room.roomId).notifier).setAll(all);
       await WidgetsBinding.instance.endOfFrame;
       idx = _items.indexWhere((it) => it is _BubbleItem && it.msg.id == messageId);
       if (idx < 0) return;
     }
     setState(() => _highlightedId = messageId);
     // List is reverse:true — Scrollable.ensureVisible via the row's key is the
     // robust way to land on it regardless of variable row heights.
     final ctx = _rowKeys[messageId]?.currentContext;
     if (ctx != null) {
       await Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 300));
     }
     await Future.delayed(const Duration(milliseconds: 1500));
     if (mounted) setState(() => _highlightedId = null);
   }
   ```
3. Add `String? _highlightedId;`. In the bubble builder, when `msg.id == _highlightedId`, wrap with a brief highlight (e.g. an `AnimatedContainer` tint) and attach a `GlobalKey` per visible row to `_rowKeys[msg.id]` so `ensureVisible` can target it.

> The list already keys rows by `msg-{clientMsgId ?? id}` and uses `findChildIndexCallback`; reuse that keying. Prefer `Scrollable.ensureVisible` over manual offset math given variable bubble heights.

- [ ] **Step 4: Run to verify pass** → `cd app && flutter test test/conversation/conversation_scroll_test.dart` → PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/conversation/conversation_page.dart app/test/conversation/conversation_scroll_test.dart
git commit -m "feat(search): scroll-to-message + highlight from results

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Global search on the chat-rooms list

**Files:**
- Create: `app/lib/inbox/global_search_page.dart`
- Modify: `app/lib/screens/inbox/home_screen.dart` (AppBar action / search entry)
- Test: `app/test/inbox/global_search_page_test.dart`

**Interfaces:**
- Consumes: `globalSearchProvider`, `inboxStateProvider` (room display names), the `_openRoom` flow.
- Produces: a global search page; tapping a hit opens its room focused on the message.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/inbox/global_search_page_test.dart`: override `messageDbProvider` (ffi) seeded with messages across two rooms; pump `GlobalSearchPage`; type a query matching both; assert results are **grouped by room** (a room header per group) and tapping a hit invokes the navigation callback with `(roomId, messageId)`.

- [ ] **Step 2: Run to verify failure** → FAIL.

- [ ] **Step 3: Implement the page**

Create `app/lib/inbox/global_search_page.dart` — mirrors `MessageSearchPage` but uses `globalSearchProvider(query)`, groups hits by `roomId` (resolve display names via `inboxStateProvider` + `profileStoreProvider`), and exposes `onOpen(String roomId, String messageId)`.

- [ ] **Step 4: Wire the entry point**

In `home_screen.dart`, add a search icon to the AppBar `actions` (line ~128–164) that pushes `GlobalSearchPage`. On a result tap, reuse the existing `_openRoom(room)` path (line ~255) and pass the `messageId` so the conversation focuses it (extend `_openRoom` / `ConversationPage` construction to accept an initial `focusMessageId` that calls `_focusMessage` on first build).

```dart
IconButton(
  key: const Key('home-search'),
  icon: const Icon(Icons.search),
  onPressed: () => Navigator.of(context).push(GlobalSearchPage.route(
    onOpen: (roomId, messageId) {
      final room = ref.read(inboxStateProvider).rooms.firstWhere((r) => r.roomId == roomId);
      Navigator.of(context).pop();
      _openRoom(room, focusMessageId: messageId);
    },
  )),
),
```

Add `import '../../inbox/global_search_page.dart';` and thread `focusMessageId` through `_openRoom` → `ConversationPage` → `_focusMessage` (Task 10).

- [ ] **Step 5: Run to verify pass** → `cd app && flutter test test/inbox/global_search_page_test.dart` → PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/inbox/global_search_page.dart app/lib/screens/inbox/home_screen.dart app/test/inbox/global_search_page_test.dart
git commit -m "feat(search): global cross-room search on the rooms list

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Milestone-2 verification (REQUIRED)

- [ ] **Step 1: Full local CI gate**

Run: `cd app && dart format --output=none --set-exit-if-changed . && flutter analyze && flutter test`
Expected: clean, all pass.

- [ ] **Step 2: On-device** (both phones, one at a time, via `ios-deploy.sh` — UDIDs in Global Constraints):
- In-channel: open chat-info → 🔍 → type a word → tap a result → conversation jumps to and highlights it.
- Search a word older than the recent window → still found (full history) → tapping loads + scrolls to it.
- Global: home → search → results grouped by room → tap opens the room at the message.
- Accent-insensitivity (`cafe` finds `café`) and prefix (`lov` finds `love`).

- [ ] **Step 3: Finalize**

Use `superpowers:finishing-a-development-branch` to open the PR.

---

## Self-Review (completed during planning)

- **Spec coverage:** §4 store/sync → Tasks 1–5; §4.6 multi-device → no code (each device's own DB falls out of Task 1's per-device key); §5 search/FTS/ranking → Tasks 7–8; §5.3 in-channel + scroll-to-message → Tasks 9–10; §5.4 global → Task 11; §6 no server changes → honored (HWM subscribe reuses existing replay); §8 testing incl. on-device → Tasks 6 & 12. Migration safety (§4.3) → `onUpgrade` + rebuildable-projection note in Task 1.
- **Placeholder scan:** UI tasks (9–11) describe widget structure rather than full literal trees because they adapt to existing palette/widget conventions the implementer reads in-file; all data-layer tasks carry complete code. Acceptable per "follow established patterns."
- **Type consistency:** `SearchHit`, `MessageDb` method names, `messageDbProvider`, and provider record-arg shapes are consistent across Tasks 1–11.
