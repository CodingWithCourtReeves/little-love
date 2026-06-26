import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Plays the short "message sent" / "message received" chime while a chat room
/// is open, and fires a light haptic on receive.
///
/// Audio goes through a native system-sound channel
/// (`AudioServicesPlaySystemSound` on iOS), so it respects the hardware silent
/// switch, mixes with other audio instead of pausing it, and never touches the
/// call/voice `AVAudioSession`. Haptics use the standard platform haptic API
/// (independent of the silent switch, per iOS norms).
///
/// Injected via [messageFeedbackProvider] so tests can swap in a recorder.
class MessageFeedback {
  MessageFeedback({MethodChannel? channel, DateTime Function()? now})
    : _channel = channel ?? const MethodChannel('little_love/message_sounds'),
      _now = now ?? DateTime.now;

  final MethodChannel _channel;
  final DateTime Function() _now;

  /// Collapse a burst of inbound rows (e.g. a reconnect replay landing several
  /// messages at once) into a single chime + haptic instead of machine-gunning.
  static const _throttle = Duration(milliseconds: 150);
  DateTime? _lastReceived;

  /// User tapped send: a soft outgoing blip. Naturally rate-limited by the tap,
  /// so it is not throttled.
  void sent() {
    _play('playSent');
  }

  /// A partner message arrived while the room is on screen: a gentle incoming
  /// chime plus a light haptic. Throttled so a burst lands as one cue.
  void received() {
    final t = _now();
    if (_lastReceived != null && t.difference(_lastReceived!) < _throttle) {
      return;
    }
    _lastReceived = t;
    _play('playReceived');
    try {
      HapticFeedback.lightImpact().catchError((_) {});
    } catch (_) {
      // Binding not yet initialized (e.g. a pure unit test): haptics are
      // best-effort, never essential.
    }
  }

  /// Fire-and-forget the native chime. A missing or failing handler (no native
  /// side, an unsupported platform, a transient error) must never surface as an
  /// unhandled async error or a crash report — a dropped chime is harmless.
  void _play(String method) {
    _channel.invokeMethod<void>(method).catchError((_) {});
  }
}

final messageFeedbackProvider = Provider<MessageFeedback>(
  (ref) => MessageFeedback(),
);
