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

  /// Replace a message identified by [fromId] with [toMsg] in place. If no row
  /// matches (replay race, peer message), fall back to [add] so we never lose
  /// data.
  void promote({required String fromId, required Msg toMsg}) {
    final idx = state.indexWhere((m) => m.id == fromId);
    if (idx < 0) {
      add(toMsg);
      return;
    }
    final next = [...state];
    next[idx] = toMsg;
    state = next;
  }

  /// Flip the [SendStatus] on a row identified by [id]. No-op if not found.
  void updateStatus(String id, SendStatus status) {
    final idx = state.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final next = [...state];
    next[idx] = state[idx].copyWith(sendStatus: status);
    state = next;
  }
}

final messageStoreProvider =
    NotifierProvider.family<MessageStore, List<Msg>, String>(MessageStore.new);
