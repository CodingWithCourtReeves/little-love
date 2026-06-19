import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'room.dart';

@immutable
class InboxState {
  const InboxState({required this.rooms});

  final List<Room> rooms;

  InboxState copyWith({List<Room>? rooms}) =>
      InboxState(rooms: rooms ?? this.rooms);

  static const InboxState empty = InboxState(rooms: []);
}

class InboxNotifier extends Notifier<InboxState> {
  @override
  InboxState build() => InboxState.empty;

  void setRooms(List<Room> rooms) {
    state = state.copyWith(rooms: List.unmodifiable(rooms));
  }

  /// Rename a room in place, preserving members + createdAt. No-op if the
  /// room isn't in the inbox yet (e.g., RoomRenamed arriving before Rooms
  /// would be a server bug, but the notifier shouldn't crash on it).
  void renameRoom(String roomId, String name) {
    var changed = false;
    final next = <Room>[];
    for (final r in state.rooms) {
      if (r.roomId == roomId) {
        changed = true;
        next.add(
          Room(
            roomId: r.roomId,
            name: name,
            members: r.members,
            createdAt: r.createdAt,
          ),
        );
      } else {
        next.add(r);
      }
    }
    if (!changed) return;
    state = state.copyWith(rooms: List.unmodifiable(next));
  }

  /// Drop `username` from `roomId`. If no members remain in the room, the
  /// room itself is removed (server cascades; client mirrors so the
  /// inbox doesn't render an empty ghost room).
  void removeMember(String roomId, String username) {
    final updated = <Room>[];
    for (final r in state.rooms) {
      if (r.roomId != roomId) {
        updated.add(r);
        continue;
      }
      final newMembers = r.members
          .where((m) => m.username != username)
          .toList(growable: false);
      final membersLeft = newMembers.isNotEmpty;
      if (membersLeft) {
        updated.add(
          Room(
            roomId: r.roomId,
            name: r.name,
            members: newMembers,
            createdAt: r.createdAt,
          ),
        );
      }
    }
    state = state.copyWith(rooms: List.unmodifiable(updated));
  }
}

final inboxStateProvider = NotifierProvider<InboxNotifier, InboxState>(
  InboxNotifier.new,
);

/// Flips to true the first time the server's room list lands (a `Rooms` frame),
/// and stays true. Lets the UI tell "no rooms yet, still syncing" apart from
/// "genuinely unpaired" — so a paired user doesn't flash the pairing screen on
/// launch before their rooms arrive over the socket.
final inboxSyncedProvider = StateProvider<bool>((ref) => false);

/// The room to open by default ("home"): the partner DM if one exists,
/// otherwise the most recently created room. Returns null for an empty inbox.
String? defaultHomeRoomId(List<Room> rooms, String selfUsername) {
  if (rooms.isEmpty) return null;
  for (final r in rooms) {
    if (r.shape(selfUsername) == RoomShape.partner) return r.roomId;
  }
  final sorted = [...rooms]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return sorted.first.roomId;
}
