import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether a given user (the partner) is currently online, per server
/// `Presence` frames. Server-authoritative and transient — never persisted, so
/// it defaults to offline until the server says otherwise (e.g. on connect, or
/// when the partner comes online).
class PresenceNotifier extends FamilyNotifier<bool, String> {
  @override
  bool build(String username) => false;

  void setOnline(bool online) => state = online;
}

final presenceProvider =
    NotifierProvider.family<PresenceNotifier, bool, String>(
      PresenceNotifier.new,
    );
