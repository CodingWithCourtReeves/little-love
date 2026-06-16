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

  /// Flip the [SendStatus] on a row identified by [id]. No-op if not found.
  /// The outbox send path uses this to mark a row `failed` on error, or to
  /// reset it to `sending` when the user taps to retry.
  void updateStatus(String id, SendStatus status) {
    final idx = state.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final next = [...state];
    next[idx] = state[idx].copyWith(sendStatus: status);
    state = next;
  }

  /// Mark the given message ids as read (the partner has seen them → double
  /// heart). Ids not in the buffer are ignored. Driven by an inbound
  /// `ReadFrame` relayed from the server.
  void markRead(List<String> ids) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    var changed = false;
    final next = [
      for (final m in state)
        if (wanted.contains(m.id) && m.sendStatus != SendStatus.read)
          () {
            changed = true;
            return m.copyWith(sendStatus: SendStatus.read);
          }()
        else
          m,
    ];
    if (changed) state = next;
  }
}

final messageStoreProvider =
    NotifierProvider.family<MessageStore, List<Msg>, String>(MessageStore.new);
