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

/// Total unread incoming messages across all rooms — drives the app-icon badge.
/// Counts messages newer than each room's last-read marker, excluding the
/// user's own ([selfUsername]) messages. Keyed by username so the family caches
/// correctly.
final totalUnreadProvider = Provider.family<int, String>((ref, selfUsername) {
  final rooms = ref.watch(inboxStateProvider).rooms;
  final lastRead = ref.watch(readStateProvider);
  var total = 0;
  for (final r in rooms) {
    final marker = lastRead[r.roomId];
    for (final m in ref.watch(messageStoreProvider(r.roomId))) {
      if (m.from == selfUsername) continue;
      if (marker == null || m.ts.isAfter(marker)) total++;
    }
  }
  return total;
});
