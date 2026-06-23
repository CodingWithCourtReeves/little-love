// Glare resolution + ring timing (spec §5). Pure helpers the call controller
// (D5) uses to converge two simultaneous calls and to bound ringing.

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
