import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Wraps a single audio call's [RTCPeerConnection]: mic capture, offer/answer,
/// trickle ICE. Pure WebRTC mechanics — no signaling, CallKit, or crypto
/// knowledge; the controller drives it and ferries the (encrypted) SDP/ICE.
class CallSession {
  CallSession({required this.iceServers, this.forceRelay = false});

  /// ICE servers shaped for `RTCConfiguration` (from `fetchIceServers`).
  final List<Map<String, dynamic>> iceServers;

  /// Force traffic through TURN (relay) — debug aid to exercise the Cloudflare
  /// leg even on a LAN where a direct P2P path would otherwise win.
  final bool forceRelay;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  final _localCandidates = StreamController<RTCIceCandidate>.broadcast();
  final _connectionStates =
      StreamController<RTCPeerConnectionState>.broadcast();

  /// Local ICE candidates to trickle to the peer (encode + send as CallIce).
  Stream<RTCIceCandidate> get onLocalCandidate => _localCandidates.stream;

  /// Peer-connection state changes (drives connecting → active / failed).
  Stream<RTCPeerConnectionState> get onConnectionState =>
      _connectionStates.stream;

  Future<void> _ensurePc() async {
    if (_pc != null) return;
    final config = <String, dynamic>{
      'iceServers': iceServers,
      if (forceRelay) 'iceTransportPolicy': 'relay',
      'sdpSemantics': 'unified-plan',
    };
    final pc = await createPeerConnection(config);
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) _localCandidates.add(candidate);
    };
    pc.onConnectionState = (state) => _connectionStates.add(state);
    // Mic capture — audio only.
    final stream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': false,
    });
    _localStream = stream;
    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }
    _pc = pc;
  }

  /// Caller: create the SDP offer (sets local description).
  Future<String> createOffer() async {
    await _ensurePc();
    final offer = await _pc!.createOffer(<String, dynamic>{});
    await _pc!.setLocalDescription(offer);
    final sdp = offer.sdp;
    if (sdp == null) throw StateError('WebRTC produced a null offer SDP');
    return sdp;
  }

  /// Callee: apply the remote offer and produce an answer (sets local + remote).
  Future<String> acceptOffer(String remoteSdp) async {
    await _ensurePc();
    await _pc!.setRemoteDescription(RTCSessionDescription(remoteSdp, 'offer'));
    final answer = await _pc!.createAnswer(<String, dynamic>{});
    await _pc!.setLocalDescription(answer);
    final sdp = answer.sdp;
    if (sdp == null) throw StateError('WebRTC produced a null answer SDP');
    return sdp;
  }

  /// Caller: apply the remote answer.
  Future<void> setAnswer(String remoteSdp) async {
    await _pc?.setRemoteDescription(RTCSessionDescription(remoteSdp, 'answer'));
  }

  /// Add a trickled remote ICE candidate (decoded from a CallIce payload).
  Future<void> addRemoteCandidate(Map<String, dynamic> json) async {
    await _pc?.addCandidate(
      RTCIceCandidate(
        json['candidate'] as String?,
        json['sdpMid'] as String?,
        (json['sdpMLineIndex'] as num?)?.toInt(),
      ),
    );
  }

  /// Encode a local candidate to the JSON shape carried in a CallIce payload.
  static Map<String, dynamic> encodeCandidate(RTCIceCandidate c) =>
      <String, dynamic>{
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };

  /// Mute/unmute the local mic.
  void setMicEnabled(bool enabled) {
    for (final t
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  Future<void> dispose() async {
    await _localStream?.dispose();
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    await _localCandidates.close();
    await _connectionStates.close();
  }
}
