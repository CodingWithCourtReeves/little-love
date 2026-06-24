// Pure call state machine (spec §5). No timers, sockets, or I/O — every
// transition is a method that returns the next [CallState] or throws
// [StateError] on an illegal transition. The controller (D5) drives it from
// signaling + CallKit events and performs the side effects.

enum CallPhase { idle, dialing, ringing, connecting, active, ended }

enum CallDirection { outgoing, incoming }

/// Terminal outcome, recorded when [CallPhase.ended] is reached. Drives the
/// call-log entry (completed / missed / declined / ...).
enum CallOutcome { completed, missed, declined, cancelled, busy, failed }

class CallState {
  const CallState._({
    required this.phase,
    this.callId,
    this.direction,
    this.outcome,
    this.isVideo = false,
  });

  /// The initial, callless state.
  const CallState.idle() : this._(phase: CallPhase.idle);

  final CallPhase phase;
  final String? callId;
  final CallDirection? direction;

  /// Whether this is a video call (vs audio-only) — drives which call screen the
  /// overlay renders. Preserved across every transition.
  final bool isVideo;

  /// Set only when [phase] is [CallPhase.ended].
  final CallOutcome? outcome;

  bool get isActive => phase == CallPhase.active;
  bool get isEnded => phase == CallPhase.ended;

  // ── Outgoing ────────────────────────────────────────────────────────────
  CallState placeCall(String callId, {bool video = false}) {
    _require(CallPhase.idle, 'placeCall');
    return CallState._(
      phase: CallPhase.dialing,
      callId: callId,
      direction: CallDirection.outgoing,
      isVideo: video,
    );
  }

  CallState remoteAnswered() {
    _require(CallPhase.dialing, 'remoteAnswered');
    return _to(CallPhase.connecting);
  }

  // ── Incoming ────────────────────────────────────────────────────────────
  CallState incoming(String callId, {bool video = false}) {
    _require(CallPhase.idle, 'incoming');
    return CallState._(
      phase: CallPhase.ringing,
      callId: callId,
      direction: CallDirection.incoming,
      isVideo: video,
    );
  }

  CallState accept() {
    _require(CallPhase.ringing, 'accept');
    return _to(CallPhase.connecting);
  }

  /// Demote a would-be video call to audio (the local camera was denied /
  /// unavailable). Valid only before the call ends.
  CallState markAudioOnly() {
    if (isEnded || phase == CallPhase.idle) {
      throw StateError('markAudioOnly not valid from $phase');
    }
    return CallState._(
      phase: phase,
      callId: callId,
      direction: direction,
      outcome: outcome,
    );
  }

  // ── Media ───────────────────────────────────────────────────────────────
  CallState iceConnected() {
    _require(CallPhase.connecting, 'iceConnected');
    return _to(CallPhase.active);
  }

  CallState iceFailed() {
    if (!_isLive) {
      throw StateError('iceFailed not valid from $phase');
    }
    return _ended(CallOutcome.failed);
  }

  // ── Termination ───────────────────────────────────────────────────────────
  /// No-answer expiry (caller's dial timer or callee's ring timer).
  CallState timeout() {
    if (phase != CallPhase.dialing && phase != CallPhase.ringing) {
      throw StateError('timeout not valid from $phase');
    }
    return _ended(CallOutcome.missed);
  }

  /// End/decline/cancel. [reason] ∈ {hangup, decline, busy, timeout, cancel};
  /// the resulting [CallOutcome] also depends on the current phase.
  CallState hangup(String reason) {
    if (phase == CallPhase.idle || phase == CallPhase.ended) {
      throw StateError('hangup not valid from $phase');
    }
    return _ended(_outcomeFor(reason));
  }

  CallOutcome _outcomeFor(String reason) {
    switch (reason) {
      case 'decline':
        return CallOutcome.declined;
      case 'busy':
        return CallOutcome.busy;
      case 'cancel':
        return CallOutcome.cancelled;
      case 'timeout':
        return CallOutcome.missed;
      case 'hangup':
      default:
        if (phase == CallPhase.active) return CallOutcome.completed;
        // Hung up before connecting: the caller cancelled; for the callee it
        // reads as a missed call.
        return direction == CallDirection.outgoing
            ? CallOutcome.cancelled
            : CallOutcome.missed;
    }
  }

  bool get _isLive =>
      phase == CallPhase.dialing ||
      phase == CallPhase.ringing ||
      phase == CallPhase.connecting;

  CallState _to(CallPhase p) => CallState._(
    phase: p,
    callId: callId,
    direction: direction,
    isVideo: isVideo,
  );

  CallState _ended(CallOutcome o) => CallState._(
    phase: CallPhase.ended,
    callId: callId,
    direction: direction,
    outcome: o,
    isVideo: isVideo,
  );

  void _require(CallPhase expected, String op) {
    if (phase != expected) {
      throw StateError('$op not valid from $phase (expected $expected)');
    }
  }
}
