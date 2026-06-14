import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/message.dart';

class MessageStore extends FamilyNotifier<List<Msg>, String> {
  @override
  List<Msg> build(String roomId) => const [];

  /// Append a message. Idempotent on `Msg.id` — re-applying replays from the
  /// server won't double-up the buffer.
  void add(Msg msg) {
    if (state.any((m) => m.id == msg.id)) return;
    state = [...state, msg];
  }

  /// Replace the buffer wholesale (e.g. on initial replay).
  void setAll(List<Msg> messages) {
    state = List.unmodifiable(messages);
  }

  /// Swap an optimistic local echo (keyed by `clientMsgId`) for the
  /// authoritative server row, preserving its position in the buffer. Used
  /// when the server echoes back the sender's own self-copy. Idempotent:
  /// if `server.id` is already present, do nothing (a duplicate echo); if no
  /// echo with `clientMsgId` exists (e.g. it was never rendered), fall back to
  /// a plain idempotent append.
  void reconcile(String clientMsgId, Msg server) {
    if (state.any((m) => m.id == server.id)) return;
    final idx = state.indexWhere((m) => m.id == clientMsgId);
    if (idx == -1) {
      add(server);
      return;
    }
    final next = [...state];
    next[idx] = server;
    state = List.unmodifiable(next);
  }
}

final messageStoreProvider =
    NotifierProvider.family<MessageStore, List<Msg>, String>(MessageStore.new);
