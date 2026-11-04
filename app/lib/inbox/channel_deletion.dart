/// Asking the server to delete a channel for both partners, and the rule the
/// confirmation sheet uses before it lets you ask.
library;

import 'dart:async';

import '../wire/frames.dart';
import '../wire/live_connection.dart';

/// How a delete request ended, from the deleter's side.
enum DeleteChannelOutcome {
  /// The server deleted it.
  deleted,

  /// The server has no such room for me: it was deleted elsewhere (both of
  /// us at once, or while this phone missed it). No `RoomDeleted` will come,
  /// so the caller removes it here itself.
  alreadyGone,

  /// It's the couple's last room, which can never be deleted.
  lastRoom,

  /// No live connection: nothing was sent.
  offline,

  /// The server refused, or didn't answer in time. The channel still exists.
  failed,
}

/// Whether [typed] confirms deleting the channel [name]: the same text,
/// ignoring capitals and surrounding spaces. A deliberate step, not a
/// spelling test; an emoji in the name still has to be typed.
bool channelNameMatches(String typed, String name) {
  final t = typed.trim().toLowerCase();
  return t.isNotEmpty && t == name.trim().toLowerCase();
}

/// Send `DeleteRoom` for [roomId] and wait for the server's answer about
/// **this** room. The answer is the durable step, so the caller confirms
/// only on [DeleteChannelOutcome.deleted] (an optimistic delete the server
/// never did would have the channel reappear on the next room list).
///
/// Listens before sending so a fast reply can't be missed. Only frames that
/// name [roomId] count: `RoomDeleted`, or an `Error` carrying that `room_id`.
/// `UnknownRoom` for it means the room is already gone
/// ([DeleteChannelOutcome.alreadyGone]). Errors about other requests in
/// flight are ignored.
Future<DeleteChannelOutcome> requestChannelDeletion({
  required LiveConnection? conn,
  required String roomId,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (conn == null) return DeleteChannelOutcome.offline;
  final answer = Completer<DeleteChannelOutcome>();
  final sub = conn.incoming.listen((f) {
    final outcome = switch (f) {
      RoomDeletedFrame(roomId: final id) when id == roomId =>
        DeleteChannelOutcome.deleted,
      RoomErrorFrame(roomId: final id, :final code) when id == roomId =>
        switch (code) {
          'UnknownRoom' => DeleteChannelOutcome.alreadyGone,
          'LastRoom' => DeleteChannelOutcome.lastRoom,
          _ => DeleteChannelOutcome.failed,
        },
      _ => null,
    };
    if (outcome != null && !answer.isCompleted) answer.complete(outcome);
  });
  // The subscription MUST go on every exit, timeout included: the stream
  // outlives this request.
  final timer = Timer(timeout, () {
    if (!answer.isCompleted) answer.complete(DeleteChannelOutcome.failed);
  });
  conn.send(DeleteRoomFrame(roomId: roomId).toJson());
  try {
    return await answer.future;
  } finally {
    timer.cancel();
    // Not awaited: nothing depends on the cancel finishing.
    unawaited(sub.cancel());
  }
}
