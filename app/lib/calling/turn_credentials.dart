import 'dart:async';

import '../wire/frames.dart';
import '../wire/live_connection.dart';

/// How long to wait for the server's `CallTurnGrant` before proceeding with no
/// relay. Generous enough for a Cloudflare round-trip; short enough that call
/// setup isn't held hostage by a stalled grant.
const _turnFetchTimeout = Duration(seconds: 10);

/// Request ICE servers for [callId] over the authenticated WebSocket and return
/// them shaped for `RTCPeerConnection` — a list of
/// `{ 'urls': .., 'username': .., 'credential': .. }` maps to place under the
/// `iceServers` config key.
///
/// Degrades rather than throws: returns an empty list if the grant doesn't
/// arrive within [timeout], the connection drops, or the server withholds the
/// relay. The caller can still attempt a direct/host-candidate connection,
/// matching the server's degrade-don't-abort behaviour.
Future<List<Map<String, dynamic>>> fetchIceServers(
  LiveConnection conn,
  String callId, {
  Duration timeout = _turnFetchTimeout,
}) async {
  // Subscribe BEFORE sending so a fast reply can't be missed.
  final grant = conn.incoming.firstWhere(
    (f) => f is CallTurnGrantFrame && f.callId == callId,
  );
  conn.send(CallTurnRequestFrame(callId: callId).toJson());
  try {
    final frame = await grant.timeout(timeout);
    return iceServersFromGrant(frame as CallTurnGrantFrame);
  } catch (_) {
    // Timeout, or the stream closed before a match (connection drop).
    return const <Map<String, dynamic>>[];
  }
}

/// Extract the `iceServers` list from a grant, defensively. The provider object
/// is `{ "iceServers": [ ... ] }`; an empty/garbage object yields an empty list.
List<Map<String, dynamic>> iceServersFromGrant(CallTurnGrantFrame frame) {
  final raw = frame.iceServers['iceServers'];
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList(growable: false);
}
