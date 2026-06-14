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

/// Room ids whose invite screen the user has dismissed via "Done". A solo room
/// with a pending invite normally force-routes to `CreateChatInviteScreen`;
/// once dismissed it falls through to the (empty) conversation so the user can
/// wait for their partner without being trapped on the code. The pending invite
/// itself is left intact — the partner still needs that code. Session-scoped.
class DismissedInvitesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void dismiss(String roomId) {
    if (state.contains(roomId)) return;
    state = Set.unmodifiable({...state, roomId});
  }
}

final dismissedInvitesProvider =
    NotifierProvider<DismissedInvitesNotifier, Set<String>>(
      DismissedInvitesNotifier.new,
    );
