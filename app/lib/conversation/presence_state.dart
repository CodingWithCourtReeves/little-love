import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A partner's presence: whether they're online, and (when offline) the time of
/// their last session. Server-authoritative and transient — defaults to offline
/// with no last-seen until the server says otherwise (on connect or change).
class PartnerPresence {
  const PartnerPresence({required this.online, this.lastSeen});
  final bool online;
  final DateTime? lastSeen;
}

/// A given user's (the partner's) presence, per server `Presence` frames.
/// Server-authoritative and transient — never persisted, so it defaults to
/// offline until the server says otherwise (e.g. on connect, or when the
/// partner comes online).
class PresenceNotifier extends FamilyNotifier<PartnerPresence, String> {
  @override
  PartnerPresence build(String username) =>
      const PartnerPresence(online: false);

  /// Apply a server Presence frame. `lastSeen` is meaningful only when offline.
  void set(bool online, {DateTime? lastSeen}) =>
      state = PartnerPresence(online: online, lastSeen: lastSeen);
}

final presenceProvider =
    NotifierProvider.family<PresenceNotifier, PartnerPresence, String>(
      PresenceNotifier.new,
    );
