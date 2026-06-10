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
}

final inboxStateProvider = NotifierProvider<InboxNotifier, InboxState>(
  InboxNotifier.new,
);
