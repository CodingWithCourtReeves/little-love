import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'outbox_store.dart';

typedef OutboxSend =
    void Function(
      String roomId,
      Map<String, String> bodies,
      String clientMsgId,
    );

/// Drains the persistent outbox over a live WS connection. Rows are removed
/// only when their echoed [MessageFrame] arrives (handled by
/// [RoomMessageRouter]), not after a successful `send` — the WS write is
/// fire-and-forget at the transport layer.
///
/// Each drain instance also remembers which `client_msg_id`s it has already
/// pushed during its lifetime. A drain instance lives as long as a single
/// WS-data cycle (the provider rebuilds on every `liveConnectionProvider`
/// transition), so on reconnect everything is eligible again.
class OutboxDrain {
  OutboxDrain({required this.store, required this.send});

  final OutboxStore store;
  final OutboxSend send;

  Future<void>? _inflight;
  final Set<String> _sentThisCycle = <String>{};

  /// Idempotent: if a drain is already running, returns the in-flight future.
  Future<void> kick() {
    final existing = _inflight;
    if (existing != null) return existing;
    final f = runOnce();
    _inflight = f;
    return f.whenComplete(() => _inflight = null);
  }

  /// Iterates pending rows in order and stops at the first transport error.
  /// Public for tests.
  Future<void> runOnce() async {
    final rows = await store.pending();
    for (final row in rows) {
      if (_sentThisCycle.contains(row.clientMsgId)) continue;
      try {
        send(row.roomId, row.bodies, row.clientMsgId);
        _sentThisCycle.add(row.clientMsgId);
        await store.markAttempt(row.clientMsgId);
      } catch (e) {
        await store.markAttempt(row.clientMsgId, error: e.toString());
        return;
      }
    }
  }

  /// Drop the per-cycle de-dup memory so a retry can resend. With no arg,
  /// clears every id (used by tests + a future "drain everything" hook).
  /// With [clientMsgId], clears just that row — the retry path uses this so
  /// a failed message can resend without waiting for a WS reconnect.
  void resetCycle({String? clientMsgId}) {
    if (clientMsgId == null) {
      _sentThisCycle.clear();
    } else {
      _sentThisCycle.remove(clientMsgId);
    }
  }
}

/// Wires the live connection in as the [OutboxSend] callable. The store and
/// connection are read non-throwingly: until both are in `data` state the
/// drain is a no-op that swallows `kick()` calls. The provider rebuilds as
/// each dependency settles, so the first real drain happens automatically
/// when the WS reaches `data`.
final outboxDrainProvider = Provider<OutboxDrain>((ref) {
  final store = ref.watch(outboxStoreProvider).valueOrNull;
  final connAsync = ref.watch(liveConnectionProvider);
  final conn = connAsync.valueOrNull;

  if (store == null) {
    return OutboxDrain(
      store: _NoopOutboxStore.instance,
      send: (_, _, _) {
        throw StateError('outbox store not ready');
      },
    );
  }

  final drain = OutboxDrain(
    store: store,
    send: (roomId, bodies, clientMsgId) {
      if (conn == null) throw StateError('not connected');
      conn.send(
        SendFrame(
          roomId: roomId,
          bodies: bodies,
          clientMsgId: clientMsgId,
        ).toJson(),
      );
    },
  );

  if (conn != null) {
    // Fire-and-forget kick on every WS-data transition.
    Future<void>(() => drain.kick());
  }

  return drain;
});

/// Returned by [outboxDrainProvider] while the SQLite store is still opening.
/// `pending()` returns empty, so `runOnce` is a no-op; the real drain
/// replaces this once the store resolves.
class _NoopOutboxStore implements OutboxStore {
  const _NoopOutboxStore._();
  static const instance = _NoopOutboxStore._();

  @override
  Future<void> enqueue({
    required String clientMsgId,
    required String roomId,
    required Map<String, String> bodies,
    DateTime? createdAt,
  }) async {}

  @override
  Future<List<OutboxRow>> pending() async => const [];

  @override
  Future<OutboxRow?> lookup(String clientMsgId) async => null;

  @override
  Future<bool> remove(String clientMsgId) async => false;

  @override
  Future<void> markAttempt(
    String clientMsgId, {
    String? error,
    bool reset = false,
  }) async {}
}

/// UUID helper exposed so [outbox_rehydrate] and the send path agree on
/// generation. Riverpod-overridable in tests.
final outboxIdGenProvider = Provider<String Function()>(
  (_) =>
      () => const Uuid().v4(),
);
