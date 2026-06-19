import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'read_state_provider.dart';

/// Mark [roomId] read locally and tell the server, without changing any
/// selection. Called from [ConversationPage] on mount: opening a chat clears
/// its unread badge and flips the partner's bubbles to a double heart.
/// Accepts any Riverpod reader ([WidgetRef], [Ref], or [ProviderContainer]).
void markRoomRead(dynamic reader, String roomId) {
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
  final upTo = messages
      .map((m) => m.id)
      .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  final conn =
      (reader.read(liveConnectionProvider) as AsyncValue<LiveConnection>)
          .valueOrNull;
  if (conn == null) return;
  conn.send(MarkReadFrame(roomId: roomId, upToMessageId: upTo).toJson());
}
