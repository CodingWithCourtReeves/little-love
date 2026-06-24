import 'dart:convert';

/// What kind of device capture happened during a call.
enum PrivacyKind { screenshot, recording }

/// A privacy event exchanged peer-to-peer over the call's WebRTC data channel
/// (E2EE via DTLS — it never touches the server, exactly like the media). It
/// tells the partner that this device captured the call so their app can react:
/// flash a notice, and pause their outgoing video while the partner records.
class PrivacyEvent {
  const PrivacyEvent(this.kind, {this.active = false});

  final PrivacyKind kind;

  /// For [PrivacyKind.recording]: whether screen recording started (true) or
  /// stopped (false). Always false for a screenshot (a one-shot event).
  final bool active;

  String encode() => jsonEncode(<String, Object?>{
    't': kind.name,
    if (kind == PrivacyKind.recording) 'a': active,
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
