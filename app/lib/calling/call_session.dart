import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Wraps a single call's [RTCPeerConnection]: mic (and, for video calls, camera)
/// capture, offer/answer, trickle ICE. Pure WebRTC mechanics — no signaling,
/// CallKit, or crypto knowledge; the controller drives it and ferries the
/// (encrypted) SDP/ICE. Media stays E2EE by construction (DTLS-SRTP between the
/// two phones — TURN only relays ciphertext), audio and video alike.
class CallSession {
  CallSession({
    required this.iceServers,
    this.video = false,
    this.forceRelay = false,
  });

  /// ICE servers shaped for `RTCConfiguration` (from `fetchIceServers`).
  final List<Map<String, dynamic>> iceServers;

  /// Whether to capture and send a camera track (video call). If the camera is
  /// unavailable / denied we transparently fall back to audio-only — check
  /// [hasVideo] after the first offer/answer to see what actually started.
  final bool video;

  /// Force traffic through TURN (relay) — debug aid to exercise the Cloudflare
  /// leg even on a LAN where a direct P2P path would otherwise win.
  final bool forceRelay;

  /// Ceiling for the camera encoding. 6 Mbps gives 1080p motion headroom while
  /// staying sane over a TURN relay; WebRTC only uses what the scene needs
  /// (`qualityLimitationReason: none` until it hits this cap).
  static const int _maxVideoBitrate = 6 * 1000 * 1000;

  /// Target capture resolution. iOS picks the closest supported camera format,
  /// so these are targets, not hard requirements (no throw if unmet). We do NOT
  /// pin a frame rate: forcing one (e.g. 60) crashes `startCaptureWithDevice`
  /// when the chosen format can't hit it, and the camera already runs ≤60 on its
  /// own. Sent as the legacy `mandatory.minWidth/minHeight` shape iOS reads.
  static const int _videoWidth = 1920;
  static const int _videoHeight = 1080;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _hasVideo = false;

  // Debug telemetry (video calls): periodic getStats sampling.
  Timer? _statsTimer;
  int _lastBytesSent = 0;
  DateTime? _lastStatsAt;
  final _statsCtl = StreamController<String>.broadcast();

  /// A one-line debug summary of the live send/receive video stats, updated
  /// every couple of seconds (for an on-screen overlay). Empty until the first
  /// sample.
  Stream<String> get onStats => _statsCtl.stream;

  final _localCandidates = StreamController<RTCIceCandidate>.broadcast();
  final _connectionStates =
      StreamController<RTCPeerConnectionState>.broadcast();
  final _remoteStreams = StreamController<MediaStream>.broadcast();

  /// Local ICE candidates to trickle to the peer (encode + send as CallIce).
  Stream<RTCIceCandidate> get onLocalCandidate => _localCandidates.stream;

  /// Peer-connection state changes (drives connecting → active / failed).
  Stream<RTCPeerConnectionState> get onConnectionState =>
      _connectionStates.stream;

  /// The partner's media stream once their tracks arrive — the UI binds this to
  /// the remote video renderer. Fires again if the stream is replaced.
  Stream<MediaStream> get onRemoteStream => _remoteStreams.stream;

  /// The local capture stream (mic + optional camera) for the self-preview.
  MediaStream? get localStream => _localStream;

  /// Whether a camera track actually started (false if video was requested but
  /// the camera was denied/unavailable, or for an audio-only call).
  bool get hasVideo => _hasVideo;

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
    // Surface the partner's stream for the remote renderer.
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) _remoteStreams.add(event.streams.first);
    };

    final stream = await _capture();
    _localStream = stream;
    for (final track in stream.getAudioTracks()) {
      await pc.addTrack(track, stream);
    }
    for (final track in stream.getVideoTracks()) {
      final sender = await pc.addTrack(track, stream);
      _hasVideo = true;
      await _capVideoBitrate(sender);
    }
    _pc = pc;
    if (_hasVideo) _startStatsLogging();
  }

  /// Periodic video telemetry (debug aid): the actual encoded resolution, frame
  /// rate, send bitrate, and WebRTC's reason for limiting quality (cpu /
  /// bandwidth / none) — the field that distinguishes a capture problem from an
  /// encoder downscale. Watch with `devicectl device process launch --console`.
  void _startStatsLogging() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final pc = _pc;
      if (pc == null) return;
      try {
        final now = DateTime.now();
        final reports = await pc.getStats();
        String tx = '…', rx = '…';
        for (final r in reports) {
          final v = r.values;
          final isVideo = v['kind'] == 'video' || v['mediaType'] == 'video';
          if (!isVideo) continue;
          if (r.type == 'outbound-rtp') {
            final bytes = (v['bytesSent'] as num?)?.toInt() ?? 0;
            final dt = _lastStatsAt == null
                ? 2.0
                : now.difference(_lastStatsAt!).inMilliseconds / 1000.0;
            final kbps = dt > 0
                ? ((bytes - _lastBytesSent) * 8 / dt / 1000).round()
                : 0;
            _lastBytesSent = bytes;
            _lastStatsAt = now;
            tx =
                '${v['frameWidth']}x${v['frameHeight']} '
                '@${v['framesPerSecond']}fps ${kbps}k '
                'lim:${v['qualityLimitationReason']}';
          } else if (r.type == 'inbound-rtp') {
            rx =
                '${v['frameWidth']}x${v['frameHeight']} @${v['framesPerSecond']}fps';
          }
        }
        final line = 'TX $tx  |  RX $rx';
        debugPrint('VSTAT $line');
        if (!_statsCtl.isClosed) _statsCtl.add(line);
      } catch (e) {
        debugPrint('VSTAT getStats failed: $e');
      }
    });
  }

  /// Acquire mic (+ camera for a video call). If the camera is denied/missing we
  /// retry audio-only so the call still connects — the controller then advertises
  /// it as an audio call.
  Future<MediaStream> _capture() async {
    if (!video) {
      return navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': false,
      });
    }
    // Pre-warm the microphone permission with an audio-only request BEFORE the
    // camera capture session starts. Asking for mic + camera together while the
    // mic permission is still undetermined races two iOS permission dialogs
    // against a live AVCaptureSession and hard-crashes the app — which is why a
    // video call only worked after an audio call had already granted the mic.
    // Prompting for the mic first (no camera running) settles it, exactly like an
    // audio call does, so the combined request below finds both grants in place.
    await _prewarmMicPermission();
    // Request 1080p via the legacy mandatory shape (iOS selects the nearest
    // camera format; no throw if unmet). No frame-rate key — the camera picks a
    // rate its format supports, avoiding the startCapture crash.
    try {
      return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': <String, dynamic>{
          'mandatory': <String, dynamic>{
            'minWidth': '$_videoWidth',
            'minHeight': '$_videoHeight',
          },
          'facingMode': 'user',
          'optional': <Map<String, dynamic>>[],
        },
      });
    } catch (e) {
      debugPrint('call: camera capture failed ($e) — falling back to audio');
      return navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': false,
      });
    }
  }

  /// Trigger (and settle) the microphone permission via a throwaway audio-only
  /// stream, so the subsequent camera capture never races the mic dialog. Cheap
  /// and idempotent once the permission is granted.
  Future<void> _prewarmMicPermission() async {
    try {
      final s = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': false,
      });
      for (final t in s.getTracks()) {
        await t.stop();
      }
      await s.dispose();
    } catch (e) {
      debugPrint('call: mic permission pre-warm failed: $e');
    }
  }

  Future<void> _capVideoBitrate(RTCRtpSender sender) async {
    try {
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        params.encodings = [RTCRtpEncoding(maxBitrate: _maxVideoBitrate)];
      } else {
        for (final e in encodings) {
          e.maxBitrate = _maxVideoBitrate;
        }
      }
      await sender.setParameters(params);
    } catch (e) {
      debugPrint('call: setParameters (bitrate cap) failed: $e');
    }
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

  /// Turn the local camera on/off (stops sending video without renegotiating).
  void setCameraEnabled(bool enabled) {
    for (final t
        in _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = enabled;
    }
  }

  /// Flip between the front and back camera.
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    await Helper.switchCamera(tracks.first);
  }

  Future<void> dispose() async {
    _statsTimer?.cancel();
    await _statsCtl.close();
    await _localStream?.dispose();
    await _pc?.close();
    await _pc?.dispose();
    _pc = null;
    await _localCandidates.close();
    await _connectionStates.close();
    await _remoteStreams.close();
  }
}
