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

/// Drains the persistent outbox over a live WS connection. Rows are removed
/// only when their echoed [MessageFrame] arrives (handled by
/// [RoomMessageRouter]), not after a successful `send` — the WS write is
/// fire-and-forget at the transport layer.
class OutboxDrain {
  OutboxDrain({required this.store, required this.send});

  final OutboxStore store;
  final OutboxSend send;

  Future<void>? _inflight;

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

/// Wires the live connection in as the [OutboxSend] callable. Throws when
/// constructed before either the store or the connection is ready — callers
/// are expected to await both providers first.
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
    // Fire-and-forget kick on every WS-data transition.
    Future<void>(() => drain.kick());
  }

  return drain;
});

/// UUID helper exposed so [outbox_rehydrate] and the send path agree on
/// generation. Riverpod-overridable in tests.
final outboxIdGenProvider = Provider<String Function()>(
  (_) => () => const Uuid().v4(),
);
