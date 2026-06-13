import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// One row in the persistent outbound queue. `bodyCipher` is the base64
/// envelope produced by [encryptOutgoing] — plaintext is never persisted.
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

/// SQLite-backed outbox. Lives at `<app-support>/outbox.db` in production;
/// tests open an in-memory database via [OutboxStore.test].
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
    await _db.insert(
      'outbox',
      {
        'client_msg_id': clientMsgId,
        'room_id': roomId,
        'body_cipher': bodyCipher,
        'created_at': ts,
        'attempts': 0,
        'last_error': null,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<OutboxRow>> pending() async {
    final rows = await _db.query('outbox', orderBy: 'created_at ASC');
    return rows.map(_rowFromMap).toList(growable: false);
  }

  Future<OutboxRow?> lookup(String clientMsgId) async {
    final rows = await _db.query(
      'outbox',
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowFromMap(rows.first);
  }

  /// Returns `true` iff a row was deleted.
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
      'UPDATE outbox SET attempts = attempts + 1, last_error = ? '
      'WHERE client_msg_id = ?',
      [error, clientMsgId],
    );
  }

  OutboxRow _rowFromMap(Map<String, Object?> r) => OutboxRow(
        clientMsgId: r['client_msg_id'] as String,
        roomId: r['room_id'] as String,
        bodyCipher: r['body_cipher'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          r['created_at'] as int,
          isUtc: true,
        ),
        attempts: r['attempts'] as int,
        lastError: r['last_error'] as String?,
      );
}

/// Opened lazily on first read. Riverpod overrides in tests use
/// [OutboxStore.test] with their own in-memory database.
final outboxStoreProvider = FutureProvider<OutboxStore>((ref) {
  return OutboxStore.open();
});
