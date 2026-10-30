import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Plays the short "message sent" / "message received" chime while a chat room
/// is open, and the haptics that go with chat moments: a light tap on receive,
/// the love-tap heartbeat, and a tap when the partner's reaction lands.
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
  /// chime plus a light haptic, or the [heartbeat] when it is a [loveTap].
  /// Throttled so a burst lands as one cue.
  void received({bool loveTap = false}) {
    final t = _now();
    if (_lastReceived != null && t.difference(_lastReceived!) < _throttle) {
      return;
    }
    _lastReceived = t;
    _play('playReceived');
    if (loveTap) {
      heartbeat();
    } else {
      _impact(HapticFeedback.lightImpact);
    }
  }

  /// Gap between the two beats of [heartbeat]: close enough to read as one
  /// "lub-dub", far enough apart that the Taptic Engine plays both.
  static const heartbeatGap = Duration(milliseconds: 130);
  Timer? _secondBeat;

  /// The love-tap haptic (#76): a medium beat, then a light one
  /// [heartbeatGap] later. Played when I tap the composer heart, and (via
  /// [received]) when a love tap arrives. Two built-in impacts rather than a
  /// Core Haptics pattern, which would need a plugin.
  void heartbeat() {
    _impact(HapticFeedback.mediumImpact);
    _secondBeat?.cancel();
    _secondBeat = Timer(
      heartbeatGap,
      () => _impact(HapticFeedback.lightImpact),
    );
  }

  /// Delay before the [reactionReceived] tap, so it lands on the reaction's
  /// pop-in overshoot rather than ahead of anything visible.
  static const reactionDelay = Duration(milliseconds: 150);
  DateTime? _lastReaction;
  Timer? _reactionTap;

  /// The partner's reaction landed live while the room is on screen (#77): a
  /// light tap, timed to its pop-in. No chime: a reaction is not a message.
  /// Throttled like [received] so a reconnect burst lands as one tap.
  void reactionReceived() {
    final t = _now();
    if (_lastReaction != null && t.difference(_lastReaction!) < _throttle) {
      return;
    }
    _lastReaction = t;
    _reactionTap?.cancel();
    _reactionTap = Timer(
      reactionDelay,
      () => _impact(HapticFeedback.lightImpact),
    );
  }

  /// Fire-and-forget one haptic. Best-effort: a missing binding (a pure unit
  /// test) or a platform error must never surface, so both are swallowed.
  void _impact(Future<void> Function() haptic) {
    try {
      haptic().catchError((_) {});
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
