import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/room_message_router.dart';
import '../wire/live_connection.dart';
import 'call_controller.dart';

/// Start the call stack on [container] and keep it running whether or not the
/// app is drawing frames. Called once from `main`.
///
/// A VoIP push can wake the app in the background, where iOS draws no frames.
/// That starves two things a call needs:
///
/// - Anything a screen starts. The home screen used to create the call
///   controller and the room router, so a woken app never heard the invite and
///   never loaded the room an answer needs.
/// - Riverpod refreshes. A mounted provider scope only rebuilds invalidated
///   providers inside a widget build, so after a socket drop the connection
///   never came back. Reading a provider rebuilds it on the spot, so a drop
///   reads the connection again instead of waiting for a frame.
void keepCallStackRunning(ProviderContainer container) {
  // The controller first, so it's listening before the connection hands its
  // buffered frames (a held CallInvite among them) to the first subscriber.
  container.listen(callControllerProvider, (_, _) {});
  container.listen<AsyncValue<LiveConnection>>(liveConnectionProvider, (
    _,
    next,
  ) {
    final conn = next.valueOrNull;
    // An error (signed out) can still carry the old, dead connection.
    if (conn == null || next.isLoading || next.hasError) return;
    // Same turn as the controller's own subscription, so both get the buffer.
    container.read(roomMessageRouterProvider);
    unawaited(
      conn.closed.then(
        // After the provider's own invalidateSelf, which runs first.
        (_) => Future(() => container.read(liveConnectionProvider)),
      ),
    );
  }, fireImmediately: true);
}
