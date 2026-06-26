import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/message.dart';
import 'link_preview.dart';

/// An edit that arrived before its target row, held until the row lands. Carries
/// the requester so authorship can be re-validated at apply time (see
/// [MessageStore._maybeApplyEdit]).
class _PendingEdit {
  const _PendingEdit(this.requestedBy, this.text, this.preview);
  final String requestedBy;
  final String text;
  final LinkPreview? preview;
}

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

  /// Server ids the partner has read (→ double heart). A `ReadFrame` can arrive
  /// before the row it refers to is in the buffer — notably for a link-preview
  /// message, whose send is delayed by the sender's OG fetch, so the partner's
  /// read receipt can beat the self-copy echo that reconciles the optimistic
  /// row to its server id. Recording the read here lets [add]/[reconcile] apply
  /// it when the row finally lands, instead of dropping it on the floor.
  final Set<String> _read = {};

  /// Edits for messages not yet in the buffer, keyed `targetId → edit`. An edit
  /// frame can arrive before its target — the target hasn't been received, or
  /// the optimistic→server-id reconcile hasn't happened yet (routine for a link-
  /// preview send, whose echo trails the partner's frames). Recording it here
  /// lets [add]/[reconcile] apply it when the row lands instead of dropping it.
  /// Latest edit wins; the requester is kept so authorship is re-validated on
  /// apply (a spoofed deferred edit must not mutate the target).
  final Map<String, _PendingEdit> _edited = {};

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
    // A read receipt and/or an edit for this id may have arrived before the row
    // did; apply them now rather than leaving the bubble stale.
    final m = _maybeApplyEdit(_read.contains(msg.id) ? _markedRead(msg) : msg);
    state = [...state, m];
  }

  /// [msg] with its send status promoted to read, unless it's already read.
  static Msg _markedRead(Msg msg) => msg.sendStatus == SendStatus.read
      ? msg
      : msg.copyWith(sendStatus: SendStatus.read);

  /// Apply any deferred edit recorded for [msg]'s id (consuming it), re-checking
  /// that the edit's requester authored the message. A spoofed deferred edit is
  /// dropped, leaving the message unchanged.
  Msg _maybeApplyEdit(Msg msg) {
    final e = _edited.remove(msg.id);
    if (e == null || msg.from != e.requestedBy) return msg;
    return _withEdit(msg, e.text, e.preview);
  }

  /// [base] rewritten with edited text/preview and the edited flag set. Built by
  /// hand (not `copyWith`) so an edit that removed a URL can clear the preview to
  /// null, which `copyWith`'s `?? this` semantics can't express.
  static Msg _withEdit(Msg base, String text, LinkPreview? preview) => Msg(
    id: base.id,
    from: base.from,
    to: base.to,
    body: text,
    ts: base.ts,
    replayed: base.replayed,
    clientMsgId: base.clientMsgId,
    sendStatus: base.sendStatus,
    attachment: base.attachment,
    linkPreview: preview,
    reactions: base.reactions,
    callOutcome: base.callOutcome,
    edited: true,
    replyTo: base.replyTo,
  );

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

  /// Apply an edit onto [targetId], requested by [requestedBy], replacing its
  /// text with [text] and its link preview with [preview] (null clears it), and
  /// flagging it edited. Only the author of a message may edit it: if the target
  /// is present and was written by someone else, this is a spoofed edit — drop it
  /// (both partners share the room key, so either could craft this frame). If the
  /// target isn't in the buffer yet, defer it (see [_edited]); authorship is
  /// re-checked when the row lands. Idempotent for a given edit.
  void applyEdit(
    String targetId, {
    required String requestedBy,
    required String text,
    LinkPreview? preview,
  }) {
    // A message its author already unsent can't be edited (and a deferred edit
    // must never resurrect it): drop the edit if a valid tombstone exists.
    if (_validlyTombstoned(targetId, requestedBy)) return;
    final idx = state.indexWhere((m) => m.id == targetId);
    if (idx < 0) {
      _edited[targetId] = _PendingEdit(requestedBy, text, preview);
      return;
    }
    if (state[idx].from != requestedBy) return; // spoofed edit
    final next = [...state];
    next[idx] = _withEdit(state[idx], text, preview);
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
    //
    // If a read receipt for this server id already arrived (it can beat the
    // echo for a preview message), promote the swapped-in row to read now —
    // the echo itself always carries read:false.
    final swapped = server.copyWith(clientMsgId: clientMsgId);
    final withRead = _read.contains(server.id) ? _markedRead(swapped) : swapped;
    next[idx] = _maybeApplyEdit(withRead);
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
  /// heart). Records the ids so a row that lands *after* its receipt (a
  /// preview message whose echo trails the read) still becomes read via
  /// [add]/[reconcile]. Driven by an inbound `ReadFrame` relayed from the
  /// server.
  void markRead(List<String> ids) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return;
    _read.addAll(wanted);
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
