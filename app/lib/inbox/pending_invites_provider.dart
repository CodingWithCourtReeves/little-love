import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wire/frames.dart';

/// Pending invites keyed by roomId. Populated when `RoomCreated` carries a
/// `pending_invite` payload (the room creator's session). Consumed by
/// `CreateChatInviteScreen` to render the 4-word code + QR.
class PendingInvitesNotifier extends Notifier<Map<String, PendingInvite>> {
  @override
  Map<String, PendingInvite> build() => const {};

  void set(String roomId, PendingInvite invite) {
    final next = Map<String, PendingInvite>.from(state);
    next[roomId] = invite;
    state = Map.unmodifiable(next);
  }

  void clear(String roomId) {
    final next = Map<String, PendingInvite>.from(state);
    next.remove(roomId);
    state = Map.unmodifiable(next);
  }
}

final pendingInvitesProvider =
    NotifierProvider<PendingInvitesNotifier, Map<String, PendingInvite>>(
      PendingInvitesNotifier.new,
    );
