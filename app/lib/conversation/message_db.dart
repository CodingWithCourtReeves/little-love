import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../attachment/attachment_descriptor.dart';
import '../wire/message.dart';
import 'link_preview.dart';
import 'message_db_key.dart';
import 'message_search.dart';

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
  static const schemaVersion = 2;

  /// SQLCipher-backed impl living at `<app-support>/messages.db`.
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

  /// Test factory: wrap an already-open sqflite [Database] (typically the ffi
  /// in-memory one), skipping the native SQLCipher layer.
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
    await db.execute(
      'CREATE INDEX messages_room_id_idx ON messages(room_id, id)',
    );
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
    await _createFts(db);
  }

  static Future<void> onUpgrade(Database db, int oldV, int newV) async {
    // NB: the CLAUDE.md "schema-only migrations" rule governs the server's
    // Postgres SQL migrations. This is the local SQLCipher *cache*, a rebuildable
    // projection of the server stream — so a deterministic backfill that reads
    // only its own already-local rows is safe here (and far better UX than
    // dropping the table and forcing a full re-replay on next launch). A future
    // gnarly change may instead DROP the affected tables and let replay re-seed.
    if (oldV < 2) {
      await _createFts(db);
      // Seed the new FTS index from rows already persisted under v1.
      await db.execute(
        'INSERT INTO messages_fts(rowid, body) '
        'SELECT rowid, body FROM messages WHERE deleted = 0',
      );
    }
  }

  /// The FTS5 search index over message [body], kept in lockstep with the
  /// `messages` content table via triggers. `unicode61 remove_diacritics 2`
  /// gives case- and accent-insensitive word/prefix matching; soft-deleted rows
  /// (`deleted = 1`) are dropped from the index by the UPDATE trigger.
  static Future<void> _createFts(Database db) async {
    await db.execute('''
      CREATE VIRTUAL TABLE messages_fts USING fts5(
        body,
        content='messages',
        content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2'
      )
    ''');
    await db.execute('''
      CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body)
          VALUES('delete', old.rowid, old.body);
      END
    ''');
    await db.execute('''
      CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body)
          VALUES('delete', old.rowid, old.body);
        INSERT INTO messages_fts(rowid, body)
          SELECT new.rowid, new.body WHERE new.deleted = 0;
      END
    ''');
  }

  Future<void> upsert(Msg msg, {required String roomId});
  Future<List<Msg>> messagesFor(String roomId);

  /// Swap an optimistic row (keyed by [clientMsgId]) for its authoritative
  /// server row, keeping [clientMsgId] on the reconciled row. Mirrors
  /// [MessageStore.reconcile]: idempotent, and drops the optimistic row if the
  /// server id was already validly tombstoned.
  Future<void> reconcile(String clientMsgId, Msg server);

  /// Apply an unsend onto [targetId]. Only the author may unsend: a delete whose
  /// [requestedBy] doesn't match a present target's author is dropped (spoofed).
  /// Records a tombstone so a later out-of-order [upsert] stays suppressed.
  Future<void> applyDelete(String targetId, {required String requestedBy});

  /// Set [username] → [emoji] on [targetId], or remove it when [emoji] is empty.
  /// No-op if the target isn't stored.
  Future<void> applyReaction(String targetId, String username, String emoji);

  /// Mark the given ids' send status as read (double-heart).
  Future<void> markRead(List<String> ids);

  /// Max stored server id for [roomId] (delta-sync anchor), or null if empty.
  Future<String?> highWaterMark(String roomId);

  /// Full-text search over message bodies, ranked by BM25 blended with a mild
  /// recency boost. Scoped to [roomId] when given (in-channel), otherwise across
  /// all rooms (global). Empty/whitespace queries return nothing.
  Future<List<SearchHit>> search(
    String query, {
    String? roomId,
    int limit = 50,
  });

  /// Wipe all local state (used on sign-out).
  Future<void> clear();
}

class SqliteMessageDb implements MessageDb {
  SqliteMessageDb(this._db);
  final Database _db;

  @override
  Future<void> upsert(Msg msg, {required String roomId}) async {
    // A validly-tombstoned id never re-enters the projection.
    final tomb = await _db.query(
      'tombstones',
      where: 'target_id = ?',
      whereArgs: [msg.id],
      limit: 1,
    );
    if (tomb.isNotEmpty && tomb.first['requested_by'] == msg.from) return;
    await _db.insert(
      'messages',
      _toRow(msg, roomId),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _advanceHwm(roomId, msg.id);
  }

  @override
  Future<List<Msg>> messagesFor(String roomId) async {
    final rows = await _db.query(
      'messages',
      where: 'room_id = ? AND deleted = 0',
      whereArgs: [roomId],
      orderBy: 'id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<void> reconcile(String clientMsgId, Msg server) async {
    final tomb = await _db.query(
      'tombstones',
      where: 'target_id = ?',
      whereArgs: [server.id],
      limit: 1,
    );
    if (tomb.isNotEmpty && tomb.first['requested_by'] == server.from) {
      // The authoritative id was already unsent; drop the optimistic echo.
      await _db.delete('messages', where: 'id = ?', whereArgs: [clientMsgId]);
      return;
    }
    final existing = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [server.id],
      limit: 1,
    );
    final n = await _db.update(
      'messages',
      {..._toRow(server, server.to), 'client_msg_id': clientMsgId},
      where: 'id = ?',
      whereArgs: [clientMsgId],
    );
    if (n == 0 && existing.isEmpty) {
      // No optimistic row to swap and no server row yet: plain idempotent insert.
      await upsert(
        server.copyWith(clientMsgId: clientMsgId),
        roomId: server.to,
      );
    } else if (existing.isNotEmpty) {
      // Server id already present (duplicate echo): drop the optimistic row.
      await _db.delete('messages', where: 'id = ?', whereArgs: [clientMsgId]);
    } else {
      await _advanceHwm(server.to, server.id);
    }
  }

  @override
  Future<void> applyDelete(
    String targetId, {
    required String requestedBy,
  }) async {
    final row = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [targetId],
      limit: 1,
    );
    if (row.isNotEmpty && row.first['from_user'] != requestedBy) {
      return; // spoofed delete: only the author may unsend
    }
    await _db.insert('tombstones', {
      'target_id': targetId,
      'requested_by': requestedBy,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _db.update(
      'messages',
      {'deleted': 1, 'deleted_by': requestedBy},
      where: 'id = ?',
      whereArgs: [targetId],
    );
  }

  @override
  Future<void> applyReaction(
    String targetId,
    String username,
    String emoji,
  ) async {
    final row = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [targetId],
      limit: 1,
    );
    if (row.isEmpty) return;
    final reactions =
        (jsonDecode(row.first['reactions'] as String) as Map<String, Object?>)
            .map((k, v) => MapEntry(k, v as String));
    if (emoji.isEmpty) {
      reactions.remove(username);
    } else {
      reactions[username] = emoji;
    }
    await _db.update(
      'messages',
      {'reactions': jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [targetId],
    );
  }

  @override
  Future<void> markRead(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE messages SET send_status = ${SendStatus.read.index} '
      'WHERE id IN ($placeholders)',
      ids,
    );
  }

  @override
  Future<String?> highWaterMark(String roomId) async {
    final rows = await _db.query(
      'room_sync',
      columns: ['hwm'],
      where: 'room_id = ?',
      whereArgs: [roomId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['hwm'] as String;
  }

  @override
  Future<List<SearchHit>> search(
    String query, {
    String? roomId,
    int limit = 50,
  }) async {
    final match = _toPrefixMatch(query);
    if (match.isEmpty) return const [];
    final where = StringBuffer('messages_fts MATCH ? AND m.deleted = 0');
    final args = <Object?>[match];
    if (roomId != null) {
      where.write(' AND m.room_id = ?');
      args.add(roomId);
    }
    args.add(limit);
    // bm25() is negative (most-relevant most-negative). Blend a gentle recency
    // nudge (ts is epoch-ms ≈ 1.7e12, so ts/1e15 ≈ 0.0017) that only breaks
    // near-ties toward newer messages without overpowering relevance. Order
    // ascending so the most-negative (best) score comes first.
    final rows = await _db.rawQuery('''
      SELECT m.id, m.room_id, m.from_user, m.ts, m.body,
             snippet(messages_fts, 0, '<b>', '</b>', '…', 12) AS snip,
             bm25(messages_fts) - (m.ts / 1.0e15) AS score
      FROM messages_fts
      JOIN messages m ON m.rowid = messages_fts.rowid
      WHERE $where
      ORDER BY score ASC
      LIMIT ?
    ''', args);
    return rows
        .map(
          (r) => SearchHit(
            messageId: r['id'] as String,
            roomId: r['room_id'] as String,
            from: r['from_user'] as String,
            ts: DateTime.fromMillisecondsSinceEpoch(
              r['ts'] as int,
              isUtc: true,
            ),
            snippetHtml: r['snip'] as String,
            body: r['body'] as String,
          ),
        )
        .toList(growable: false);
  }

  /// Turn user text into a safe FTS5 prefix query: lowercase, split on
  /// whitespace, strip everything but letters/digits (so FTS operators like
  /// `"`, `*`, `-`, `:` can't break the MATCH), and append `*` to each token for
  /// as-you-type prefix matching.
  static String _toPrefixMatch(String query) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))
        .where((t) => t.isNotEmpty)
        .map((t) => '"$t"*');
    return tokens.join(' ');
  }

  @override
  Future<void> clear() async {
    await _db.delete('messages');
    // Authoritatively empty the FTS index too — don't rely solely on the
    // per-row DELETE triggers — so no decrypted plaintext lingers in the FTS
    // shadow tables for the next account on this device.
    await _db.execute(
      "INSERT INTO messages_fts(messages_fts) VALUES('delete-all')",
    );
    await _db.delete('room_sync');
    await _db.delete('tombstones');
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
    'attachment': m.attachment == null
        ? null
        : jsonEncode(m.attachment!.toJson()),
    'link_preview': m.linkPreview == null
        ? null
        : jsonEncode(m.linkPreview!.toJson()),
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
            jsonDecode(r['attachment'] as String) as Map<String, Object?>,
          ),
    linkPreview: r['link_preview'] == null
        ? null
        : LinkPreview.fromJson(
            jsonDecode(r['link_preview'] as String) as Map<String, Object?>,
          ),
    callOutcome: r['call_outcome'] as String?,
    reactions: (jsonDecode(r['reactions'] as String) as Map<String, Object?>)
        .map((k, v) => MapEntry(k, v as String)),
  );
}

/// Opened lazily on first read; overridable in tests with [MessageDb.test].
final messageDbProvider = FutureProvider<MessageDb>((ref) => MessageDb.open());
