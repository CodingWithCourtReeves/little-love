import 'package:littlelove/outbox/outbox_store.dart';

/// Pure in-memory [OutboxStore] for widget / router tests. Avoids
/// `sqfliteFfiInit`, which keeps Riverpod's FutureProvider overrides from
/// settling under the AutomatedTestWidgetsFlutterBinding.
class MemoryOutboxStore implements OutboxStore {
  final Map<String, OutboxRow> _rows = {};

  @override
  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required String bodyCipher,
    DateTime? createdAt,
  }) async {
    _rows.putIfAbsent(
      clientMsgId,
      () => OutboxRow(
        clientMsgId: clientMsgId,
        roomId: roomId,
        bodyCipher: bodyCipher,
        createdAt: createdAt ?? DateTime.now().toUtc(),
        attempts: 0,
        lastError: null,
      ),
    );
  }

  @override
  Future<List<OutboxRow>> pending() async {
    final list = _rows.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<OutboxRow?> lookup(String clientMsgId) async => _rows[clientMsgId];

  @override
  Future<bool> remove(String clientMsgId) async =>
      _rows.remove(clientMsgId) != null;

  @override
  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  }) async {
    final r = _rows[clientMsgId];
    if (r == null) return;
    _rows[clientMsgId] = OutboxRow(
      clientMsgId: r.clientMsgId,
      roomId: r.roomId,
      bodyCipher: r.bodyCipher,
      createdAt: r.createdAt,
      attempts: reset ? 0 : r.attempts + 1,
      lastError: reset ? null : error,
    );
  }
}
