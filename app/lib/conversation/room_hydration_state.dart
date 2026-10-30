import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether a room's local history has been loaded into its [MessageStore].
///
/// The initial room list is only shown once every room has loaded (see
/// `inboxSyncedProvider`), but a room can still be on screen with an empty
/// store before it's hydrated from [MessageDb]: one that arrives later
/// (`RoomCreated`, `InviteConsumed`), or one whose load failed. The home list
/// reads this to tell "not loaded yet" (show no preview) from "no messages"
/// (show "No messages yet").
class RoomHydrationNotifier extends FamilyNotifier<bool, String> {
  @override
  bool build(String roomId) => false;

  /// The local cache for this room has been read (whether or not it held
  /// anything). Idempotent.
  void markHydrated() {
    if (!state) state = true;
  }
}

final roomHydratedProvider =
    NotifierProvider.family<RoomHydrationNotifier, bool, String>(
      RoomHydrationNotifier.new,
    );
