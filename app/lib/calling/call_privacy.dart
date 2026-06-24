import 'dart:convert';

/// An in-call peer event sent over the call's data channel. `screenshot` /
/// `recording` are capture-privacy events; `camera` carries the sender's camera
/// on/off state (WebRTC's track `enabled` flag doesn't propagate a mute to the
/// receiver, so we signal it explicitly); `reaction` is a tapped emoji that
/// floats up on both screens.
enum PrivacyKind { screenshot, recording, camera, reaction }

/// A privacy event exchanged peer-to-peer over the call's WebRTC data channel
/// (E2EE via DTLS — it never touches the server, exactly like the media). It
/// tells the partner that this device captured the call so their app can react:
/// flash a notice, and pause their outgoing video while the partner records.
class PrivacyEvent {
  const PrivacyEvent(this.kind, {this.active = false, this.emoji});

  final PrivacyKind kind;

  /// State flag for the stateful kinds: recording on/off, or camera on/off.
  final bool active;

  /// The emoji for a [PrivacyKind.reaction] (e.g. '❤️').
  final String? emoji;

  String encode() => jsonEncode(<String, Object?>{
    't': kind.name,
    if (kind == PrivacyKind.recording || kind == PrivacyKind.camera)
      'a': active,
    if (kind == PrivacyKind.reaction && emoji != null) 'e': emoji,
  });

  /// Parse a wire string; null if malformed or an unknown kind (forward-compat —
  /// a newer peer's event we don't understand is ignored, never a crash).
  static PrivacyEvent? decode(String s) {
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final kind = PrivacyKind.values.byName(j['t'] as String);
      return PrivacyEvent(
        kind,
        active: j['a'] == true,
        emoji: j['e'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
