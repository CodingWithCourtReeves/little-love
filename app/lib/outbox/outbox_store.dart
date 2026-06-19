import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// One row in the persistent outbound queue. `bodies` is the v0.3 per-recipient
/// fan-out map (recipient `x25519_pub_b64` → base64 ciphertext envelope from
/// [encryptOutgoing]), including the sender's own self-copy. Plaintext is never
/// persisted — only ciphertext addressed to each member's key.
class OutboxRow {
  OutboxRow({
    required this.clientMsgId,
    required this.roomId,
    required this.bodies,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
  });

  final String clientMsgId;
  final String roomId;
  final Map<String, String> bodies;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
}

/// Abstract outbound queue. The production impl is SQLite-backed; tests are
/// free to wire a pure in-memory implementation to sidestep sqflite_ffi's
/// background-isolate setup, which can interact poorly with the testWidgets
/// binding.
abstract class OutboxStore {
  /// SQLite-backed impl living at `<app-support>/outbox.db`.
  static Future<OutboxStore> open() => SqliteOutboxStore.open();

  /// Test factory: wrap an already-open sqflite [Database] (typically the
  /// ffi in-memory one).
  factory OutboxStore.test(Database db) => SqliteOutboxStore.test(db);

  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required Map<String, String> bodies,
    DateTime? createdAt,
  });

  Future<List<OutboxRow>> pending();

  Future<OutboxRow?> lookup(String clientMsgId);

  /// Returns `true` iff a row was deleted.
  Future<bool> remove(String clientMsgId);

  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  });

  /// Delete every queued row (used on sign-out so a new account on this device
  /// never re-sends the previous user's pending messages).
  Future<void> clear();
}

class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore._(this._db);

  factory SqliteOutboxStore.test(Database db) => SqliteOutboxStore._(db);

  static Future<SqliteOutboxStore> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'outbox.db');
    final db = await openDatabase(path, version: 1, onCreate: onCreate);
    return SqliteOutboxStore._(db);
  }

  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE outbox (
        client_msg_id TEXT PRIMARY KEY,
        room_id       TEXT NOT NULL,
        bodies_json   TEXT NOT NULL,
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

  @override
  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required Map<String, String> bodies,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    await _db.insert('outbox', {
      'client_msg_id': clientMsgId,
      'room_id': roomId,
      'bodies_json': jsonEncode(bodies),
      'created_at': ts,
      'attempts': 0,
      'last_error': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<List<OutboxRow>> pending() async {
    final rows = await _db.query('outbox', orderBy: 'created_at ASC');
    return rows.map(_rowFromMap).toList(growable: false);
  }

  @override
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

  @override
  Future<bool> remove(String clientMsgId) async {
    final n = await _db.delete(
      'outbox',
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
    );
    return n > 0;
  }

  @override
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

  @override
  Future<void> clear() async {
    await _db.delete('outbox');
  }

  OutboxRow _rowFromMap(Map<String, Object?> r) => OutboxRow(
    clientMsgId: r['client_msg_id'] as String,
    roomId: r['room_id'] as String,
    bodies: (jsonDecode(r['bodies_json'] as String) as Map<String, Object?>)
        .map((k, v) => MapEntry(k, v as String)),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      r['created_at'] as int,
      isUtc: true,
    ),
    attempts: r['attempts'] as int,
    lastError: r['last_error'] as String?,
  );
}

/// Opened lazily on first read. Riverpod overrides in tests can swap in
/// either [SqliteOutboxStore.test] (with an ffi DB) or a pure in-memory
/// fake that implements [OutboxStore].
final outboxStoreProvider = FutureProvider<OutboxStore>((ref) {
  return OutboxStore.open();
});
