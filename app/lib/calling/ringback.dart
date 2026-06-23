import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Caller-side ringback — the "trill" you hear while an outgoing call is dialing,
/// until the partner picks up. CallKit rings the *callee's* device but never
/// produces a caller-side ringback for a VoIP app, so we loop our own tone.
///
/// Played only by the caller, only during [CallPhase.dialing]; stopped the
/// instant the partner answers (so it never overlaps live call audio) and on any
/// end/reset. Ringback is non-essential: a failure here must never break call
/// setup, so [start] swallows its own errors.
class Ringback {
  AudioPlayer? _player;

  /// Begin looping the ringback. No-op if already ringing.
  Future<void> start() async {
    if (_player != null) return;
    final p = AudioPlayer();
    _player = p;
    try {
      await p.setLoopMode(LoopMode.one);
      await p.setAsset('assets/audio/ringback.wav');
      await p.play();
    } catch (e) {
      debugPrint('ringback start failed: $e');
      await _teardown();
    }
  }

  /// Stop ringing and release the player.
  Future<void> stop() => _teardown();

  Future<void> _teardown() async {
    final p = _player;
    _player = null;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {
      // best-effort
    }
    await p.dispose();
  }
}
