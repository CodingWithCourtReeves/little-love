import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether a room's local history has been loaded into its [MessageStore].
///
/// The room list lands before each room is hydrated from [MessageDb] (see
/// `RoomMessageRouter._subscribe`), so for a moment every store is empty. The
/// home list reads this to tell "not loaded yet" (show no preview) from "no
/// messages" (show "No messages yet"), instead of flashing the latter on
/// every launch.
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
