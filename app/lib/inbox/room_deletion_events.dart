import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A channel the server deleted, as the router applied it. [roomName] is the
/// name the app held before removing the room (the frame carries only the
/// id), for the "Kaitlyn deleted Travel" toast.
@immutable
class RoomDeletion {
  const RoomDeletion({
    required this.roomId,
    required this.roomName,
    required this.deletedBy,
  });
  final String roomId;
  final String roomName;
  final String deletedBy;
}

/// The latest live channel deletion, for the home screen to pop whoever is
/// inside that channel back to the inbox. Each [emit] sets a new object, so a
/// `ref.listen` fires once per deletion. The reconnect sweep doesn't emit: a
/// channel deleted while offline just isn't there any more.
class RoomDeletionsNotifier extends Notifier<RoomDeletion?> {
  @override
  RoomDeletion? build() => null;

  void emit(RoomDeletion deletion) => state = deletion;
}

final roomDeletionsProvider =
    NotifierProvider<RoomDeletionsNotifier, RoomDeletion?>(
      RoomDeletionsNotifier.new,
    );
