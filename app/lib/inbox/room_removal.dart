/// Removing a deleted channel from this phone, in two steps kept apart on
/// purpose: [hideRoom] takes it out of the inbox, [purgeRoomLocally] wipes its
/// data. A delete does both; a future archive would reuse only the hide (see
/// `docs/superpowers/specs/2026-11-01-delete-channel-design.md`, "Leaving room
/// for archive").
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_download.dart';
import '../conversation/message_db.dart';
import '../conversation/message_store.dart';
import '../conversation/room_hydration_state.dart';
import '../conversation/room_key_cache.dart';
import '../conversation/typing_state.dart';
import '../diagnostics/crash_reporting.dart';
import '../outbox/outbox_store.dart';
import '../profile/profile_publish_cache.dart';
import 'inbox_state.dart';
import 'read_state_provider.dart';

/// Take [roomId] out of the inbox. Synchronous, so the row is gone in the
/// same frame the deletion is applied.
void hideRoom(Ref ref, String roomId) {
  ref.read(inboxStateProvider.notifier).removeRoom(roomId);
}

/// Wipe every local trace of [roomId]: its cached history and search entries,
/// draft, decrypted media, unsent outbox rows (they'd fail forever with
/// `UnknownRoom`), read marker, in-memory state and room key. Also forgets
/// the published avatar's descriptor, since the avatar may have been uploaded
/// into this room; the next profile publish re-uploads it. Faults are
/// reported, not thrown: a partial wipe is retried by the next reconnect
/// sweep, since the room is still missing from the server's list.
Future<void> purgeRoomLocally(Ref ref, String roomId) async {
  try {
    final db = await ref.read(messageDbProvider.future);
    final media = await db.purgeRoom(roomId);
    for (final d in media) {
      await evictCachedAttachment(d);
    }
    final outbox = await ref.read(outboxStoreProvider.future);
    for (final row in await outbox.pending()) {
      if (row.roomId == roomId) await outbox.remove(row.clientMsgId);
    }
    await ref.read(profilePublishCacheProvider).setAvatar(null, null);
  } catch (e, st) {
    reportFault(e, st, context: 'room_purge');
  }
  ref.read(readStateProvider.notifier).forget(roomId);
  ref.read(roomKeyCacheProvider).invalidate(roomId);
  ref.invalidate(messageStoreProvider(roomId));
  ref.invalidate(roomHydratedProvider(roomId));
  ref.invalidate(typingProvider(roomId));
}
