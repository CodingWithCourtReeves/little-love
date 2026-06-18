import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/message.dart';

class MessageStore extends FamilyNotifier<List<Msg>, String> {
  /// Ids of messages unsent ("deleted for everyone") this session. The buffer
  /// never re-adds a tombstoned id, which keeps a delete sticky even if its
  /// target replays/arrives afterward (e.g. a delete that races ahead of its
  /// target on a live connection). Not persisted: the server replays the
  /// target before its delete on reconnect, so the tombstone re-applies itself.
  final Set<String> _deleted = {};

  @override
  List<Msg> build(String roomId) => const [];

  /// Append a message. Idempotent on `Msg.id` — re-applying replays from the
  /// server won't double-up the buffer. A tombstoned id is dropped on the spot.
  void add(Msg msg) {
    if (_deleted.contains(msg.id)) return;
    if (state.any((m) => m.id == msg.id)) return;
    state = [...state, msg];
  }

  /// Replace the buffer wholesale (e.g. on initial replay). Tombstoned ids are
  /// filtered out so a wholesale reset can't resurrect a deleted message.
  void setAll(List<Msg> messages) {
    state = List.unmodifiable(
      _deleted.isEmpty
          ? messages
          : messages.where((m) => !_deleted.contains(m.id)),
    );
  }

  /// Apply an unsend onto [targetId]: record the tombstone and drop the message
  /// if it's currently in the buffer. Idempotent. Recording the id even when
  /// the target isn't present yet means a later [add] of that id is a no-op, so
  /// a delete that arrives before its target still wins.
  void applyDelete(String targetId) {
    _deleted.add(targetId);
    final idx = state.indexWhere((m) => m.id == targetId);
    if (idx < 0) return;
    final next = [...state]..removeAt(idx);
    state = next;
  }

  /// Swap an optimistic local echo (keyed by `clientMsgId`) for the
  /// authoritative server row, preserving its position in the buffer. Used
  /// when the server echoes back the sender's own self-copy. Idempotent:
  /// if `server.id` is already present, do nothing (a duplicate echo); if no
  /// echo with `clientMsgId` exists (e.g. it was never rendered), fall back to
  /// a plain idempotent append.
  void reconcile(String clientMsgId, Msg server) {
    if (_deleted.contains(server.id)) {
      // The authoritative id was already unsent; drop the optimistic echo
      // instead of swapping in a row we'd only have to remove.
      final idx = state.indexWhere((m) => m.id == clientMsgId);
      if (idx >= 0) state = [...state]..removeAt(idx);
      return;
    }
    if (state.any((m) => m.id == server.id)) return;
    final idx = state.indexWhere((m) => m.id == clientMsgId);
    if (idx == -1) {
      add(server);
      return;
    }
    final next = [...state];
    // Keep the originating clientMsgId on the reconciled row so the list can
    // key bubbles by a stable identity across the optimistic→server id swap.
    // Without this the row's key flips on echo, remounting the bubble (and
    // re-decoding a media thumbnail) — a visible flash on send.
    next[idx] = server.copyWith(clientMsgId: clientMsgId);
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

  /// Apply a reaction onto the target message: set [username] → [emoji], or
  /// remove that user's reaction when [emoji] is empty (toggle off). No-op if
  /// the target isn't in the buffer (e.g. a reaction whose target hasn't
  /// replayed yet — targets always precede their reactions, so this is rare).
  /// Idempotent: re-applying the same value is a cheap rewrite, so the optimi-
  /// stic local apply and the server echo converge.
  void applyReaction(String targetId, String username, String emoji) {
    final idx = state.indexWhere((m) => m.id == targetId);
    if (idx < 0) return;
    final current = state[idx].reactions;
    if (emoji.isEmpty && !current.containsKey(username)) return;
    if (current[username] == emoji && emoji.isNotEmpty) return;
    final next = Map<String, String>.from(current);
    if (emoji.isEmpty) {
      next.remove(username);
    } else {
      next[username] = emoji;
    }
    final list = [...state];
    list[idx] = state[idx].copyWith(reactions: next);
    state = list;
  }

  /// Remove a message by id without tombstoning it. Used to cancel an
  /// unconfirmed outgoing send (its id is the clientMsgId): the row is dropped
  /// from the buffer and its outbox row separately, so it neither resends nor
  /// re-appears — and since the server never durably stored it, replay can't
  /// bring it back either. No-op if not present.
  void remove(String id) {
    final idx = state.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    state = [...state]..removeAt(idx);
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
