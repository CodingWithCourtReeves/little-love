import 'dart:convert';

/// An in-call peer event. `screenshot`/`recording` are capture-privacy events;
/// `camera` carries the sender's camera on/off state (since WebRTC's track
/// `enabled` flag doesn't propagate a mute to the receiver, we signal it
/// explicitly so the partner can show a cover instead of a frozen frame).
enum PrivacyKind { screenshot, recording, camera }

/// A privacy event exchanged peer-to-peer over the call's WebRTC data channel
/// (E2EE via DTLS — it never touches the server, exactly like the media). It
/// tells the partner that this device captured the call so their app can react:
/// flash a notice, and pause their outgoing video while the partner records.
class PrivacyEvent {
  const PrivacyEvent(this.kind, {this.active = false});

  final PrivacyKind kind;

  /// State flag for stateful kinds: recording on/off, or camera on/off. Unused
  /// (always false) for a screenshot, which is a one-shot event.
  final bool active;

  String encode() => jsonEncode(<String, Object?>{
    't': kind.name,
    if (kind != PrivacyKind.screenshot) 'a': active,
  });

  /// Parse a wire string; null if malformed or an unknown kind (forward-compat —
  /// a newer peer's event we don't understand is ignored, never a crash).
  static PrivacyEvent? decode(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final kind = PrivacyKind.values.byName(j['t'] as String);
      return PrivacyEvent(kind, active: j['a'] == true);
    } catch (_) {
      return null;
    }
  }
}
