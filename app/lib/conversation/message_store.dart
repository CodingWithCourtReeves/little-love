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
}

final messageStoreProvider =
    NotifierProvider.family<MessageStore, List<Msg>, String>(MessageStore.new);
