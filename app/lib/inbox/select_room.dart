import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'inbox_state.dart';
import 'read_state_provider.dart';

/// Select [roomId] as the active room and mark it read in one step. Use this
/// everywhere a room is opened (switcher tap, sidebar tap, auto-select on
/// create) so unread state stays consistent. Accepts any Riverpod reader
/// ([WidgetRef], [Ref], or [ProviderContainer]).
void selectAndMarkRead(dynamic reader, String roomId) {
  reader.read(inboxStateProvider.notifier).select(roomId);
  reader.read(readStateProvider.notifier).markRead(roomId);
  sendMarkRead(reader, roomId);
}

/// Tell the server we've read everything in [roomId] up to the latest message
/// we hold, so the sender's bubbles flip to a double heart. No-op when the room
/// is empty or the live connection isn't up yet. The watermark is the max
/// message id (ULIDs sort by time); the server only flips the partner's unread
/// rows at or below it.
void sendMarkRead(dynamic reader, String roomId) {
  final messages = reader.read(messageStoreProvider(roomId)) as List<Msg>;
  if (messages.isEmpty) return;
  // Advance the local read marker in the same breath. The unread count and the
  // app-icon badge are computed client-side off this marker; if we only told
  // the server (the path replay/resume reads take), the marker would stay stale
  // and the badge would keep counting messages the user has actually seen.
  reader.read(readStateProvider.notifier).markRead(roomId);
  final upTo = messages
      .map((m) => m.id)
      .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  final conn =
      (reader.read(liveConnectionProvider) as AsyncValue<LiveConnection>)
          .valueOrNull;
  if (conn == null) return;
  conn.send(MarkReadFrame(roomId: roomId, upToMessageId: upTo).toJson());
}
