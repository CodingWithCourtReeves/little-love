import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inbox/inbox_state.dart';
import '../inbox/select_room.dart';
import 'push_registration.dart';

/// One-time push wiring, run after the inbox has a partner room. Requests
/// notification permission, starts token registration, writes the palette key,
/// and routes notification taps (live + cold-launch) to the matching room.
///
/// Exposed as a provider so the inbox screen can `watch` it once a room exists;
/// Riverpod caches the result, so the body runs a single time per session.
final pushBootstrapProvider = Provider<void>((ref) {
  final push = ref.watch(pushServiceProvider);
  // Instantiating the registration provider starts its onToken listener, which
  // sends RegisterPush over the live socket once a token arrives.
  ref.watch(pushRegistrationProvider);

  // One palette today; the future switcher overwrites this key.
  push.setPalette('twilight');
  // Ask permission; registration fires via onToken once it's granted.
  push.requestPermission();

  void openRoom(String roomId) {
    final rooms = ref.read(inboxStateProvider).rooms;
    if (rooms.any((r) => r.roomId == roomId)) {
      selectAndMarkRead(ref, roomId);
    }
  }

  // Live taps (app already running).
  push.onTap(openRoom);
  // Cold-launch tap was buffered natively — drain it once now that we're ready.
  push.takePendingLaunchRoom().then((roomId) {
    if (roomId != null) openRoom(roomId);
  });
});
