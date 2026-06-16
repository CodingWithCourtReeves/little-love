import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'room.dart';

@immutable
class InboxState {
  const InboxState({required this.rooms, required this.selectedRoomId});

  final List<Room> rooms;
  final String? selectedRoomId;

  InboxState copyWith({
    List<Room>? rooms,
    String? selectedRoomId,
    bool clearSelection = false,
  }) {
    return InboxState(
      rooms: rooms ?? this.rooms,
      selectedRoomId: clearSelection
          ? null
          : (selectedRoomId ?? this.selectedRoomId),
    );
  }

  static const InboxState empty = InboxState(rooms: [], selectedRoomId: null);
}

class InboxNotifier extends Notifier<InboxState> {
  @override
  InboxState build() => InboxState.empty;

  void setRooms(List<Room> rooms) {
    final keepSelection =
        state.selectedRoomId != null &&
        rooms.any((r) => r.roomId == state.selectedRoomId);
    state = state.copyWith(
      rooms: List.unmodifiable(rooms),
      clearSelection: !keepSelection,
    );
  }

  void select(String roomId) {
    if (!state.rooms.any((r) => r.roomId == roomId)) {
      throw ArgumentError.value(roomId, 'roomId', 'no such room in inbox');
    }
    state = state.copyWith(selectedRoomId: roomId);
  }

  /// Drop the current selection so the detail pane returns to the
  /// "Select a conversation" surface (which carries the pair / new-chat
  /// affordances). Used by the sidebar's "+ new chat" button.
  void deselect() {
    state = state.copyWith(clearSelection: true);
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

  /// Drop `username` from `roomId`. If no humans remain in the room, the
  /// room itself is removed (server cascades; client mirrors so the
  /// inbox doesn't render an empty-bot-only ghost room).
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
      final humansLeft = newMembers.any((m) => !m.isBot);
      if (humansLeft) {
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
    final selectionStillValid =
        state.selectedRoomId == null ||
        updated.any((r) => r.roomId == state.selectedRoomId);
    state = state.copyWith(
      rooms: List.unmodifiable(updated),
      clearSelection: !selectionStillValid,
    );
  }
}

final inboxStateProvider = NotifierProvider<InboxNotifier, InboxState>(
  InboxNotifier.new,
);

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
