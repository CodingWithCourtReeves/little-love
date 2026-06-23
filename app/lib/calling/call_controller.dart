import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
import '../outbox/outbox_store.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'call_log.dart';
import 'call_session.dart';
import 'call_signaling.dart';
import 'call_state.dart';
import 'glare.dart';
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

  final ValueNotifier<CallState> state =
      ValueNotifier<CallState>(const CallState.idle());

  CallSession? _session;
  Uint8List? _sigKey;
  String? _callId;
  String? _roomId;
  String? _peerUsername;
  DateTime? _startedAt;
  String? _pendingOffer; // encrypted offer awaiting CallKit accept (incoming)
  Timer? _ringTimer;

  StreamSubscription<CallEvent?>? _ckSub;
  StreamSubscription<RoomServerFrame>? _frameSub;
  ProviderSubscription<AsyncValue<LiveConnection>>? _connListen;

  static const _uuid = Uuid();

  LiveConnection? get _conn =>
      _ref.read(liveConnectionProvider).valueOrNull;

  String? get _selfUsername =>
      _ref.read(accountProvider).valueOrNull?.username;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Place an outgoing call in [roomId].
  Future<void> placeCall(String roomId) async {
    if (state.value.phase != CallPhase.idle) return;
    final self = _selfUsername;
    final rp = _roomAndPeer(roomId, self);
    if (self == null || rp == null) return;
    final (room, peer) = rp;

    final callId = _uuid.v4(); // MUST be a UUID — CallKit requires it.
    _callId = callId;
    _roomId = roomId;
    _peerUsername = peer.username;
    _startedAt = DateTime.now().toUtc();
    state.value = state.value.placeCall(callId);

    _sigKey = await _deriveSigKey(room, peer, callId);
    if (_sigKey == null) return _fail();

    final ice = await fetchIceServers(_conn!, callId);
    _session = CallSession(iceServers: ice);
    _wireSession();

    final offer = await _session!.createOffer();
    final encOffer = await encryptSignal(_sigKey!, offer);
    _conn?.send(
      CallInviteClientFrame(roomId: roomId, callId: callId, offer: encOffer)
          .toJson(),
    );

    // Native outgoing-call UI.
    await FlutterCallkitIncoming.startCall(
      _callKitParams(callId, peer.username),
    );
    _startRingTimer();
  }

  /// Hang up / cancel the current call locally.
  Future<void> hangup({String reason = 'hangup'}) async {
    final callId = _callId;
    final roomId = _roomId;
    if (callId == null || roomId == null) return;
    _conn?.send(
      CallHangupClientFrame(roomId: roomId, callId: callId, reason: reason)
          .toJson(),
    );
    await _end(reason);
  }

  void toggleMute(bool muted) => _session?.setMicEnabled(!muted);

  void dispose() {
    _ckSub?.cancel();
    _frameSub?.cancel();
    _connListen?.close();
    _ringTimer?.cancel();
    _session?.dispose();
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
    if (offer == null || roomId == null || peer == null || self == null) return;
    if (callId != null && _callId != null && callId != _callId) return;

    final rp = _roomAndPeer(roomId, self);
    if (rp == null) return _fail();
    final (room, peerMember) = rp;

    state.value = state.value.accept();
    _sigKey ??= await _deriveSigKey(room, peerMember, _callId!);
    if (_sigKey == null) return _fail();

    final ice = await fetchIceServers(_conn!, _callId!);
    _session = CallSession(iceServers: ice);
    _wireSession();

    // `offer` is the encrypted wire string — decrypt to the raw SDP before
    // handing it to WebRTC.
    final offerSdp = await decryptSignal(_sigKey!, offer);
    final answer = await _session!.acceptOffer(offerSdp);
    final encAnswer = await encryptSignal(_sigKey!, answer);
    _conn?.send(
      CallAnswerClientFrame(roomId: roomId, callId: _callId!, answer: encAnswer)
          .toJson(),
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
      case CallInviteFrame(:final roomId, :final callId, :final from, :final offer):
        await _onIncomingInvite(roomId, callId, from, offer);
      case CallAnswerFrame(:final callId, :final answer):
        if (callId != _callId || _sigKey == null) return;
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
        await _end(reason, emitLog: false); // remote ended; they log it if caller
      default:
        break;
    }
  }

  Future<void> _onIncomingInvite(
    String roomId,
    String callId,
    String from,
    String offer,
  ) async {
    // Glare: if we're already dialing our own call, the deterministic tiebreak
    // decides. If we lose, cancel ours and accept theirs; if we win, ignore.
    if (state.value.phase == CallPhase.dialing) {
      final self = _selfUsername;
      if (self != null && glareIWin(self, from)) return; // keep ours
      await _end('cancel'); // we lost — drop ours, fall through to accept theirs
    } else if (state.value.phase != CallPhase.idle) {
      // Busy with another call.
      _conn?.send(
        CallHangupClientFrame(roomId: roomId, callId: callId, reason: 'busy')
            .toJson(),
      );
      return;
    }

    _callId = callId;
    _roomId = roomId;
    _peerUsername = from;
    _startedAt = DateTime.now().toUtc();
    _pendingOffer = offer;
    state.value = const CallState.idle().incoming(callId);

    // Show the native incoming-call screen (also fired by the VoIP push on a
    // cold wake; same call_id de-dupes).
    await FlutterCallkitIncoming.showCallkitIncoming(
      _callKitParams(callId, from),
    );
    _startRingTimer();
  }

  // ── Session wiring ────────────────────────────────────────────────────────

  void _wireSession() {
    final session = _session!;
    session.onLocalCandidate.listen((c) async {
      final roomId = _roomId;
      final callId = _callId;
      if (roomId == null || callId == null || _sigKey == null) return;
      final enc = await encryptSignal(
        _sigKey!,
        _encodeCandidate(CallSession.encodeCandidate(c)),
      );
      _conn?.send(
        CallIceClientFrame(roomId: roomId, callId: callId, candidate: enc)
            .toJson(),
      );
    });
    session.onConnectionState.listen((s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _ringTimer?.cancel();
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

  Future<Uint8List?> _deriveSigKey(Room room, Member peer, String callId) async {
    final me = await _ref.read(currentIdentityProvider.future);
    final roomKey = await _ref.read(roomKeyCacheProvider).getOrDeriveFor(
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
  Future<void> _end(String reason, {bool emitLog = true}) async {
    if (state.value.isEnded || state.value.phase == CallPhase.idle) {
      _reset();
      return;
    }
    _ringTimer?.cancel();
    final wasOutgoing = state.value.direction == CallDirection.outgoing;
    final ended = state.value.hangup(reason);
    state.value = ended;
    await FlutterCallkitIncoming.endAllCalls();
    await _session?.dispose();

    if (emitLog && wasOutgoing && ended.outcome != null) {
      await _emitCallLog(ended.outcome!);
    }
    _reset();
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
    _startedAt = null;
    _pendingOffer = null;
    _ringTimer?.cancel();
  }

  CallKitParams _callKitParams(String callId, String caller) => CallKitParams(
        id: callId,
        nameCaller: caller,
        handle: caller,
        type: 0, // audio
        extra: <String, dynamic>{'room_id': _roomId, 'call_id': callId},
        ios: const IOSParams(handleType: 'generic', supportsVideo: false),
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
