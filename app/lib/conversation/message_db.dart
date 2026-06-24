import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../attachment/attachment_descriptor.dart';
import 'link_preview.dart';
import 'message_db_key.dart';
import '../wire/message.dart';

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
