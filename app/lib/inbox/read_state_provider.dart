import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../identity/providers.dart';
import 'inbox_state.dart';

/// In-memory + persisted map of roomId → last-read message timestamp.
/// Hydrated from [ReadStateStore] on first build; every [markRead] writes
/// through to disk so the marker survives app restarts.
class ReadStateNotifier extends Notifier<Map<String, DateTime>> {
  @override
  Map<String, DateTime> build() {
    // Hydrate asynchronously; until the file loads we treat everything as
    // unmarked (conservative: shows unread rather than hiding it).
    _hydrate();
    return const {};
  }

  Future<void> _hydrate() async {
    final store = ref.read(readStateStoreProvider);
    final loaded = await store.load();
    if (loaded.isNotEmpty) {
      state = Map.unmodifiable({...loaded, ...state});
    }
  }

  void markRead(String roomId, {DateTime? at}) {
    final ts = (at ?? DateTime.now().toUtc());
    final existing = state[roomId];
    if (existing != null && !ts.isAfter(existing)) return;
    final next = Map<String, DateTime>.from(state)..[roomId] = ts;
    state = Map.unmodifiable(next);
    // Write through; fire-and-forget is fine — the in-memory state is the
    // source of truth for this session.
    ref.read(readStateStoreProvider).save(state);
  }
}

final readStateProvider =
    NotifierProvider<ReadStateNotifier, Map<String, DateTime>>(
      ReadStateNotifier.new,
    );

/// True iff [roomId] has a message newer than its last-read marker (or any
/// message at all when there is no marker yet).
final roomUnreadProvider = Provider.family<bool, String>((ref, roomId) {
  final messages = ref.watch(messageStoreProvider(roomId));
  if (messages.isEmpty) return false;
  final newest = messages
      .map((m) => m.ts)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final lastRead = ref.watch(readStateProvider)[roomId];
  if (lastRead == null) return true;
  return newest.isAfter(lastRead);
});

/// True iff any room the user is in — other than [excludeRoomId] — is unread.
/// Used for the header pill's "unread elsewhere" dot. Takes a single
/// [String] key (not a list) so the family caches/reuses scopes correctly;
/// the room set is derived internally from [inboxStateProvider].
final anyUnreadProvider = Provider.family<bool, String>((ref, excludeRoomId) {
  final rooms = ref.watch(inboxStateProvider).rooms;
  for (final r in rooms) {
    if (r.roomId == excludeRoomId) continue;
    if (ref.watch(roomUnreadProvider(r.roomId))) return true;
  }
  return false;
});

/// Unread incoming messages in one room: my partner's messages newer than the
/// room's last-read marker (all of them when there is no marker yet). Call-log
/// rows don't count: like reactions and edits they aren't conversation turns
/// (REVIEW.md, "Non-timeline kinds ... don't bump unread"). This is
/// the single per-room definition that the app-icon badge
/// ([totalUnreadProvider]), the conversation back-button badge
/// ([unreadElsewhereCountProvider]) and the home row's count all use, so they
/// never disagree. Keyed by the (me, roomId) record so the family caches per
/// room.
final roomUnreadCountProvider =
    Provider.family<int, ({String me, String roomId})>((ref, key) {
      final marker = ref.watch(
        readStateProvider.select((markers) => markers[key.roomId]),
      );
      var count = 0;
      for (final m in ref.watch(messageStoreProvider(key.roomId))) {
        if (m.from == key.me || m.callOutcome != null) continue;
        if (marker == null || m.ts.isAfter(marker)) count++;
      }
      return count;
    });

/// Total unread incoming messages across all rooms — drives the app-icon badge.
/// Sums [roomUnreadCountProvider] over every room. Keyed by username so the
/// family caches correctly.
final totalUnreadProvider = Provider.family<int, String>((ref, selfUsername) {
  var total = 0;
  for (final r in ref.watch(inboxStateProvider).rooms) {
    total += ref.watch(
      roomUnreadCountProvider((me: selfUsername, roomId: r.roomId)),
    );
  }
  return total;
});

/// Count of unread incoming messages in rooms *other than [roomId]*. Drives the
/// conversation back-button badge — "while I'm in this thread, how many messages
/// are waiting in my other threads." Excludes the user's own ([me]) messages and
/// the named room (the conversation passes its own id, so the room you're in
/// never counts even before its auto-read lands). Keyed by the (me, roomId)
/// record so the family caches per conversation.
///
/// Deliberately does *not* watch `activeRoomProvider`: the conversation clears
/// that on dispose, which would dirty this provider during teardown and leave a
/// pending refresh. Taking the room id as a parameter sidesteps that entirely.
final unreadElsewhereCountProvider =
    Provider.family<int, ({String me, String roomId})>((ref, key) {
      var total = 0;
      for (final r in ref.watch(inboxStateProvider).rooms) {
        if (r.roomId == key.roomId) continue;
        total += ref.watch(
          roomUnreadCountProvider((me: key.me, roomId: r.roomId)),
        );
      }
      return total;
    });
