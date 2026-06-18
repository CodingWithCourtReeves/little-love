import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/message.dart';

class MessageStore extends FamilyNotifier<List<Msg>, String> {
  /// Tombstones for messages unsent ("deleted for everyone") this session,
  /// mapped `targetId → username that requested the delete`. The buffer never
  /// re-adds a *validly* tombstoned id (one whose author matches the deleter),
  /// which keeps a delete sticky even if its target replays/arrives afterward
  /// (e.g. a delete that races ahead of its target on a live connection). Not
  /// persisted: the server replays the target before its delete on reconnect,
  /// so the tombstone re-applies itself.
  ///
  /// Storing the deleter (not just the id) lets us enforce the unsend invariant
  /// on the apply path: only the author of a message may unsend it. Both
  /// partners share the room key, so either side can craft a valid encrypted
  /// `kind:"delete"` naming *any* id; without this check a partner could
  /// tombstone the other's messages.
  final Map<String, String> _deleted = {};

  /// Per-session ids of sends the user cancelled before the server confirmed
  /// them. A late self-copy echo for one of these must not resurrect the
  /// bubble (see [reconcile]).
  final Set<String> _cancelled = {};

  /// True when [id] carries a tombstone authored by [from] — i.e. the delete
  /// targeting it came from the same user who wrote it. A tombstone recorded by
  /// a *different* user (a spoofed delete that raced ahead of its target) does
  /// not match, so the message survives.
  bool _validlyTombstoned(String id, String from) => _deleted[id] == from;

  @override
  List<Msg> build(String roomId) => const [];

  /// Append a message. Idempotent on `Msg.id` — re-applying replays from the
  /// server won't double-up the buffer. A validly-tombstoned id is dropped on
  /// the spot (a spoofed delete that raced ahead does not suppress it).
  void add(Msg msg) {
    if (_validlyTombstoned(msg.id, msg.from)) return;
    if (state.any((m) => m.id == msg.id)) return;
    state = [...state, msg];
  }

  /// Replace the buffer wholesale (e.g. on initial replay). Validly-tombstoned
  /// ids are filtered out so a wholesale reset can't resurrect a deleted
  /// message.
  void setAll(List<Msg> messages) {
    state = List.unmodifiable(
      _deleted.isEmpty
          ? messages
          : messages.where((m) => !_validlyTombstoned(m.id, m.from)),
    );
  }

  /// Apply an unsend onto [targetId], requested by [requestedBy]. Only the
  /// author of a message may unsend it: if the target is present and was
  /// written by someone else, this is a spoofed delete — drop it on the floor
  /// (no tombstone, no removal). Otherwise record the tombstone (so a later
  /// [add] of that id is validated against [requestedBy]) and remove the
  /// message if it's already in the buffer. Idempotent.
  void applyDelete(String targetId, {required String requestedBy}) {
    final idx = state.indexWhere((m) => m.id == targetId);
    if (idx >= 0 && state[idx].from != requestedBy) return; // spoofed delete
    _deleted[targetId] = requestedBy;
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
    if (_validlyTombstoned(server.id, server.from)) {
      // The authoritative id was already unsent; drop the optimistic echo
      // instead of swapping in a row we'd only have to remove.
      final idx = state.indexWhere((m) => m.id == clientMsgId);
      if (idx >= 0) state = [...state]..removeAt(idx);
      return;
    }
    if (state.any((m) => m.id == server.id)) return;
    final idx = state.indexWhere((m) => m.id == clientMsgId);
    if (idx == -1) {
      // No optimistic row to swap. If the user cancelled this send while it was
      // in flight, a late echo must not re-add it — drop the orphan echo.
      if (_cancelled.contains(clientMsgId)) return;
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
    // Remember the cancellation so a late server echo (the send may already
    // have reached the server) can't resurrect the bubble in [reconcile].
    _cancelled.add(id);
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
