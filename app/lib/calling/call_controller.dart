import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../conversation/room_key_cache.dart';
import '../conversation/send_fanout.dart';
import '../identity/current_identity.dart';
import '../identity/providers.dart';
import '../inbox/inbox_state.dart';
import '../inbox/room.dart';
import '../outbox/outbox_drain.dart';
import '../outbox/outbox_store.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'call_log.dart';
import 'call_session.dart';
import 'call_signaling.dart';
import 'call_state.dart';
import 'glare.dart';
import 'ringback.dart';
import 'turn_credentials.dart';

/// Orchestrates a voice call end-to-end: ties the pure [CallState] machine to
/// the encrypted signaling frames, the WebRTC [CallSession], and the native
/// CallKit UI. One active call at a time (couples app).
///
/// Foreground path (both apps open) is the primary flow here; the killed-app
/// wake path reuses the same accept handler once the woken app connects and the
/// server delivers the pending CallInvite.
class CallController {
  CallController(this._ref) {
    _attachCallKit();
    _attachFrames();
  }

  final Ref _ref;

  final ValueNotifier<CallState> state = ValueNotifier<CallState>(
    const CallState.idle(),
  );

  CallSession? _session;
  Uint8List? _sigKey;
  String? _callId;
  String? _roomId;
  String? _peerUsername;
  bool _video = false; // whether the current call is a video call
  DateTime? _startedAt;

  // Latest remote stream + a relay that survives session recreation, so the
  // video screen can render the partner's camera however late it subscribes.
  MediaStream? _remoteStream;
  final StreamController<MediaStream> _remoteStreamRelay =
      StreamController<MediaStream>.broadcast();

  /// Live debug stats line (TX/RX video resolution, fps, bitrate, limit reason)
  /// for the on-screen overlay during a video call. Empty when no sample yet.
  final ValueNotifier<String> debugStats = ValueNotifier<String>('');
  String? _pendingOffer; // encrypted offer awaiting CallKit accept (incoming)
  String?
  _pendingAcceptCallId; // accept tapped before the offer arrived (cold wake)
  Timer? _ringTimer;
  bool _ending = false; // re-entrancy guard for _end (see below)
  final Ringback _ringback = Ringback(); // caller-side dialing tone

  StreamSubscription<CallEvent?>? _ckSub;
  StreamSubscription<RoomServerFrame>? _frameSub;
  ProviderSubscription<AsyncValue<LiveConnection>>? _connListen;

  static const _uuid = Uuid();

  /// Native side-channel (shared with push) — used to tell iOS a video call is
  /// active so it can default the audio route to the speaker on session activate.
  static const _nativeChannel = MethodChannel('little_love/push');

  void _setNativeVideoCall(bool active) {
    _nativeChannel
        .invokeMethod<void>('setVideoCallActive', active)
        .catchError((_) {});
  }

  LiveConnection? get _conn => _ref.read(liveConnectionProvider).valueOrNull;

  String? get _selfUsername => _ref.read(accountProvider).valueOrNull?.username;

  /// The partner's display name for the call UI (the only other room member).
  String get peerName => _peerUsername ?? 'Partner';

  /// The local capture stream (mic + camera) for the self-preview, or null
  /// before media starts.
  MediaStream? get localStream => _session?.localStream;

  /// The partner's stream once it arrives (null until their tracks land).
  MediaStream? get remoteStream => _remoteStream;

  /// Remote-stream updates for the video screen (replays nothing — read
  /// [remoteStream] for the current value on subscribe).
  Stream<MediaStream> get onRemoteStream => _remoteStreamRelay.stream;

  /// Whether the local camera is actually capturing (false if denied / audio).
  bool get hasLocalVideo => _session?.hasVideo ?? false;

  /// Turn the local camera on/off mid-call.
  void setCameraEnabled(bool enabled) => _session?.setCameraEnabled(enabled);

  /// Flip between the front and back camera.
  Future<void> switchCamera() async => _session?.switchCamera();

  // ── Public API ────────────────────────────────────────────────────────────

  /// Place an outgoing call in [roomId]. Pass [video] for a video call.
  Future<void> placeCall(String roomId, {bool video = false}) async {
    if (state.value.phase != CallPhase.idle) return;
    final self = _selfUsername;
    final rp = _roomAndPeer(roomId, self);
    if (self == null || rp == null) return;
    final (room, peer) = rp;

    final callId = _uuid.v4(); // MUST be a UUID — CallKit requires it.
    _callId = callId;
    _roomId = roomId;
    _peerUsername = peer.username;
    _video = video;
    _startedAt = DateTime.now().toUtc();
    state.value = state.value.placeCall(callId, video: video);

    _sigKey = await _deriveSigKey(room, peer, callId);
    if (_sigKey == null) return _fail();

    final ice = await fetchIceServers(_conn!, callId);
    _session = CallSession(iceServers: ice, video: video);
    _wireSession();

    final offer = await _session!.createOffer();
    // Asked for video but the camera was denied/unavailable → the session fell
    // back to audio; advertise (and render) the call as audio to match.
    if (video && !_session!.hasVideo) {
      _video = false;
      if (state.value.phase != CallPhase.ended) {
        state.value = state.value.markAudioOnly();
      }
    }
    _setNativeVideoCall(_video);
    final encOffer = await encryptSignal(_sigKey!, offer);
    _conn?.send(
      CallInviteClientFrame(
        roomId: roomId,
        callId: callId,
        offer: encOffer,
        video: _video,
      ).toJson(),
    );

    // Native outgoing-call UI.
    await FlutterCallkitIncoming.startCall(
      _callKitParams(callId, peer.username, video: _video),
    );
    // Caller-side ringback until the partner answers (or we give up / they decline).
    unawaited(_ringback.start());
    _startRingTimer();
  }

  /// Hang up / cancel the current call locally.
  Future<void> hangup({String reason = 'hangup'}) async {
    final callId = _callId;
    final roomId = _roomId;
    if (callId == null || roomId == null) return;
    _conn?.send(
      CallHangupClientFrame(
        roomId: roomId,
        callId: callId,
        reason: reason,
      ).toJson(),
    );
    await _end(reason);
  }

  void toggleMute(bool muted) => _session?.setMicEnabled(!muted);

  void dispose() {
    _ckSub?.cancel();
    _frameSub?.cancel();
    _connListen?.close();
    _ringTimer?.cancel();
    _ringback.stop();
    _session?.dispose();
    _remoteStreamRelay.close();
    debugStats.dispose();
    state.dispose();
  }

  // ── CallKit events ──────────────────────────────────────────────────────

  void _attachCallKit() {
    _ckSub = FlutterCallkitIncoming.onEvent.listen((event) async {
      if (event == null) return;
      final body = event.body;
      final id = body is Map ? body['id'] as String? : null;
      switch (event.event) {
        case Event.actionCallAccept:
          await _onCallKitAccept(id);
        case Event.actionCallDecline:
          await hangup(reason: 'decline');
        case Event.actionCallEnded:
          await hangup(reason: 'hangup');
        case Event.actionCallToggleMute:
          final muted = body is Map ? body['isMuted'] == true : false;
          toggleMute(muted);
        default:
          break;
      }
    });
  }

  /// Callee accepted (foreground in-app, or after a VoIP wake). Needs the
  /// encrypted offer, delivered over the WS as a CallInvite.
  Future<void> _onCallKitAccept(String? callId) async {
    final offer = _pendingOffer;
    final roomId = _roomId;
    final peer = _peerUsername;
    final self = _selfUsername;
    if (offer == null || roomId == null || peer == null || self == null) {
      // VoIP cold-wake race: the user tapped Answer on the native CallKit screen
      // before the WS delivered the encrypted CallInvite. Remember the accept
      // and replay it once _onIncomingInvite lands the offer.
      _pendingAcceptCallId = callId ?? _callId;
      return;
    }
    if (callId != null && _callId != null && callId != _callId) return;

    final rp = _roomAndPeer(roomId, self);
    if (rp == null) return _fail();
    final (room, peerMember) = rp;

    // Apply-layer trust: derive the peer from room membership, not the invite's
    // `from`. A couple's room has exactly one other member — honor it over
    // whatever the frame claimed (the sig-key is derived from this member too).
    if (_peerUsername != peerMember.username) {
      _peerUsername = peerMember.username;
    }

    state.value = state.value.accept();
    _sigKey ??= await _deriveSigKey(room, peerMember, _callId!);
    if (_sigKey == null) return _fail();

    final ice = await fetchIceServers(_conn!, _callId!);
    _session = CallSession(iceServers: ice, video: _video);
    _wireSession();

    // `offer` is the encrypted wire string — decrypt to the raw SDP before
    // handing it to WebRTC.
    final offerSdp = await decryptSignal(_sigKey!, offer);
    final answer = await _session!.acceptOffer(offerSdp);
    final encAnswer = await encryptSignal(_sigKey!, answer);
    _conn?.send(
      CallAnswerClientFrame(
        roomId: roomId,
        callId: _callId!,
        answer: encAnswer,
      ).toJson(),
    );
    _pendingOffer = null;
  }

  // ── Signaling frames ──────────────────────────────────────────────────────

  void _attachFrames() {
    void subscribe(LiveConnection? conn) {
      _frameSub?.cancel();
      if (conn == null) return;
      _frameSub = conn.incoming.listen(_onFrame);
    }

    subscribe(_conn);
    // Re-attach across reconnects (liveConnectionProvider re-creates the socket).
    _connListen = _ref.listen<AsyncValue<LiveConnection>>(
      liveConnectionProvider,
      (_, next) => subscribe(next.valueOrNull),
    );
  }

  Future<void> _onFrame(RoomServerFrame f) async {
    switch (f) {
      case CallInviteFrame(
        :final roomId,
        :final callId,
        :final from,
        :final offer,
        :final video,
      ):
        await _onIncomingInvite(roomId, callId, from, offer, video);
      case CallAnswerFrame(:final callId, :final answer):
        if (callId != _callId || _sigKey == null) return;
        // The partner picked up — stop the dialing tone before any call audio
        // flows, so the ringback never overlaps the live stream.
        unawaited(_ringback.stop());
        final sdp = await decryptSignal(_sigKey!, answer);
        await _session?.setAnswer(sdp);
        if (state.value.phase == CallPhase.dialing) {
          state.value = state.value.remoteAnswered();
        }
      case CallIceFrame(:final callId, :final candidate):
        if (callId != _callId || _sigKey == null) return;
        final json = await decryptSignal(_sigKey!, candidate);
        await _session?.addRemoteCandidate(_decodeCandidate(json));
      case CallHangupFrame(:final callId, :final reason):
        if (callId != _callId) return;
        // The peer ended the call. We still run the normal end path; the
        // `wasOutgoing` check inside `_end` ensures only the caller logs it
        // (so it's recorded even when the callee hangs up).
        await _end(reason);
      default:
        break;
    }
  }

  Future<void> _onIncomingInvite(
    String roomId,
    String callId,
    String from,
    String offer,
    bool video,
  ) async {
    // Glare: if we're already dialing our own call, the deterministic tiebreak
    // decides. If we lose, cancel ours and accept theirs; if we win, ignore.
    if (state.value.phase == CallPhase.dialing) {
      final self = _selfUsername;
      if (self != null && glareIWin(self, from)) return; // keep ours
      await _end(
        'cancel',
      ); // we lost — drop ours, fall through to accept theirs
    } else if (state.value.phase != CallPhase.idle) {
      // Busy with another call.
      _conn?.send(
        CallHangupClientFrame(
          roomId: roomId,
          callId: callId,
          reason: 'busy',
        ).toJson(),
      );
      return;
    }

    _callId = callId;
    _roomId = roomId;
    _peerUsername = from;
    _video = video;
    _setNativeVideoCall(video);
    _startedAt = DateTime.now().toUtc();
    _pendingOffer = offer;
    state.value = const CallState.idle().incoming(callId, video: video);

    // Show the native incoming-call screen (also fired by the VoIP push on a
    // cold wake; same call_id de-dupes).
    await FlutterCallkitIncoming.showCallkitIncoming(
      _callKitParams(callId, from, video: video),
    );
    _startRingTimer();

    // Cold-wake race: if the user already tapped Answer on the native screen
    // before this offer arrived, the accept was deferred — replay it now.
    if (_pendingAcceptCallId == callId) {
      _pendingAcceptCallId = null;
      await _onCallKitAccept(callId);
    }
  }

  // ── Session wiring ────────────────────────────────────────────────────────

  void _wireSession() {
    final session = _session!;
    // Relay the partner's stream out to the video screen (and keep the latest
    // for late subscribers).
    session.onRemoteStream.listen((s) {
      _remoteStream = s;
      _remoteStreamRelay.add(s);
    });
    session.onStats.listen((s) => debugStats.value = s);
    session.onLocalCandidate.listen((c) async {
      final roomId = _roomId;
      final callId = _callId;
      if (roomId == null || callId == null || _sigKey == null) return;
      final enc = await encryptSignal(
        _sigKey!,
        _encodeCandidate(CallSession.encodeCandidate(c)),
      );
      _conn?.send(
        CallIceClientFrame(
          roomId: roomId,
          callId: callId,
          candidate: enc,
        ).toJson(),
      );
    });
    session.onConnectionState.listen((s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _ringTimer?.cancel();
        unawaited(_ringback.stop());
        if (state.value.phase == CallPhase.connecting) {
          state.value = state.value.iceConnected();
          FlutterCallkitIncoming.setCallConnected(_callId ?? '');
        }
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _end('hangup');
      }
    });
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<Uint8List?> _deriveSigKey(
    Room room,
    Member peer,
    String callId,
  ) async {
    final me = await _ref.read(currentIdentityProvider.future);
    final roomKey = await _ref
        .read(roomKeyCacheProvider)
        .getOrDeriveFor(
          roomId: room.roomId,
          peerX25519PubBase64: peer.x25519PubBase64,
          me: me,
        );
    return deriveSigKey(roomKey, callId);
  }

  (Room, Member)? _roomAndPeer(String roomId, String? self) {
    if (self == null) return null;
    Room? room;
    for (final r in _ref.read(inboxStateProvider).rooms) {
      if (r.roomId == roomId) {
        room = r;
        break;
      }
    }
    if (room == null) return null;
    for (final m in room.members) {
      if (m.username != self) return (room, m);
    }
    return null;
  }

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(callRingTimeout, () {
      hangup(reason: 'timeout');
    });
  }

  /// End the call: tear down WebRTC + CallKit, record the outcome, and (caller
  /// only) emit the call-log message.
  Future<void> _end(String reason) async {
    // Re-entrancy guard: endAllCalls() below fires a CallKit "ended" event that
    // re-enters via onEvent → hangup → _end. Without this, that re-entrant call
    // would _reset() our fields before _emitCallLog runs, dropping the log.
    if (_ending) return;
    if (state.value.isEnded || state.value.phase == CallPhase.idle) {
      _reset();
      return;
    }
    _ending = true;
    try {
      _ringTimer?.cancel();
      unawaited(_ringback.stop());
      final wasOutgoing = state.value.direction == CallDirection.outgoing;
      final ended = state.value.hangup(reason);
      state.value = ended;

      // Emit the call-log FIRST (caller only — the single authoritative emitter,
      // so exactly one entry regardless of who hung up), while our fields are
      // still intact, then tear down CallKit + WebRTC. A log failure must not
      // abort teardown, so it's caught here; the finally restores the
      // re-entrancy guard even if CallKit/WebRTC teardown throws (otherwise a
      // stuck `_ending = true` would brick every later call).
      if (wasOutgoing && ended.outcome != null) {
        try {
          await _emitCallLog(ended.outcome!);
        } catch (e, st) {
          debugPrint('call: call-log emit failed: $e\n$st');
        }
      }
      await FlutterCallkitIncoming.endAllCalls();
      await _session?.dispose();
      _reset();
    } finally {
      _ending = false;
    }
  }

  Future<void> _emitCallLog(CallOutcome outcome) async {
    final roomId = _roomId;
    final self = _selfUsername;
    final startedAt = _startedAt;
    if (roomId == null || self == null || startedAt == null) return;
    final rp = _roomAndPeer(roomId, self);
    if (rp == null) return;
    final (room, _) = rp;
    final duration = DateTime.now().toUtc().difference(startedAt);
    final content = buildCallLog(
      callId: _callId!,
      outcome: outcome,
      duration: outcome == CallOutcome.completed ? duration : Duration.zero,
      startedAt: startedAt,
      video: _video,
    ).encode();
    final me = await _ref.read(currentIdentityProvider.future);
    final clientMsgId = _uuid.v4();
    final frame = await buildSendFrame(
      room: room,
      me: me,
      selfUsername: self,
      plaintext: content,
      cache: _ref.read(roomKeyCacheProvider),
      clientMsgId: clientMsgId,
    );
    final store = await _ref.read(outboxStoreProvider.future);
    await store.enqueue(
      clientMsgId: clientMsgId,
      roomId: roomId,
      bodies: frame.bodies,
    );
    // Kick the outbox so the call-log actually sends now (enqueue alone just
    // persists it; the drain is what pushes it over the wire).
    await _ref.read(outboxDrainProvider).kick();
  }

  void _fail() {
    _end('hangup');
  }

  void _reset() {
    state.value = const CallState.idle();
    _session = null;
    _sigKey = null;
    _callId = null;
    _roomId = null;
    _peerUsername = null;
    _video = false;
    _setNativeVideoCall(false);
    _remoteStream = null;
    debugStats.value = '';
    _startedAt = null;
    _pendingOffer = null;
    _pendingAcceptCallId = null;
    _ringTimer?.cancel();
    unawaited(_ringback.stop());
  }

  CallKitParams _callKitParams(
    String callId,
    String caller, {
    bool video = false,
  }) => CallKitParams(
    id: callId,
    nameCaller: caller,
    handle: caller,
    type: video ? 1 : 0, // 1 = video, 0 = audio
    extra: <String, dynamic>{
      'room_id': _roomId,
      'call_id': callId,
      'video': video,
    },
    ios: IOSParams(handleType: 'generic', supportsVideo: video),
  );

  // Candidate JSON is stringified to ride inside the encrypted signaling payload.
  String _encodeCandidate(Map<String, dynamic> json) => jsonEncode(json);
  Map<String, dynamic> _decodeCandidate(String s) =>
      jsonDecode(s) as Map<String, dynamic>;
}

final callControllerProvider = Provider<CallController>((ref) {
  final c = CallController(ref);
  ref.onDispose(c.dispose);
  return c;
});
