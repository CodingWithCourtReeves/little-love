// Glare resolution + ring timing (spec §5). Pure helpers the call controller
// (D5) uses to converge two simultaneous calls and to bound ringing.

import 'call_state.dart';

/// No-answer window for both the caller's dial timer and the callee's ring
/// timer. On expiry the caller emits a `timeout` hangup (logged as missed) and
/// the callee dismisses CallKit.
const Duration callRingTimeout = Duration(seconds: 35);

/// Deterministic glare tiebreak: when both partners place a call at nearly the
/// same moment, the call initiated by the partner with the lexicographically
/// smaller username wins. Usernames are unique and known to both clients, so
/// both sides compute the same winner and converge — the loser cancels its
/// outgoing call and accepts the incoming one.
///
/// Returns true if *my* outgoing call wins (I keep dialing; my partner will
/// accept it); false if I lose (I cancel my outgoing and accept my partner's).
/// A username never glares with itself (couples have two distinct usernames),
/// but if equal we default to false so neither side deadlocks claiming victory.
bool glareIWin(String myUsername, String peerUsername) {
  return myUsername.compareTo(peerUsername) < 0;
}

/// What to do with an incoming call invite, given the call state now.
enum InviteAction {
  /// Show it and ring.
  ring,

  /// Drop it: a repeat of the call already in progress, or a glare we win.
  ignore,

  /// Refuse it as busy: a different call is already in progress.
  busy,

  /// Glare we lose: cancel our outgoing call, then ring theirs.
  yieldAndRing,
}

/// Decide an incoming invite. The server re-sends a held invite whenever the
/// callee's socket reconnects, so a repeat of the call already ringing (or
/// being answered) is ignored rather than refused as busy, which would end the
/// very call it repeats.
InviteAction inviteActionFor(
  CallState state, {
  required String inviteCallId,
  required String? self,
  required String from,
}) {
  if (state.phase == CallPhase.idle) return InviteAction.ring;
  if (state.callId == inviteCallId) return InviteAction.ignore;
  if (state.phase == CallPhase.dialing) {
    if (self != null && glareIWin(self, from)) return InviteAction.ignore;
    return InviteAction.yieldAndRing;
  }
  return InviteAction.busy;
}
