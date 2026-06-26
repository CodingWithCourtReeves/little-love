import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../diagnostics/crash_reporting.dart';
import '../identity/current_identity.dart';
import '../identity/keypair.dart';
import '../identity/providers.dart';
import 'frames.dart';

/// Single multiplexed WSS connection for the signed-in session. Owns the
/// socket lifecycle, runs the §8.5.1 handshake, and exposes a broadcast
/// stream of post-handshake room-phase frames plus an outbound JSON sink.
///
/// The handshake runs inside the same `Stream<dynamic>` subscription that
/// later serves room-phase frames — there is no listener teardown between
/// the two phases, so no inbound frame can fall on the floor between
/// "Authenticated" and the first room-phase subscriber attaching. Any
/// room-phase frame that arrives before a subscriber is buffered and
/// flushed on subscribe.
abstract class LiveConnection {
  Stream<RoomServerFrame> get incoming;

  /// Write a client → server frame. `payload` is whatever `Frame.toJson()`
  /// returned.
  void send(Object payload);

  /// Completes when this connection is no longer usable — the post-handshake
  /// socket dropped (`onDone`/`onError`) or [close] was called. Never errors.
  /// [liveConnectionProvider] awaits this to trigger a reconnect.
  Future<void> get closed;

  Future<void> close();

  /// Production constructor: opens the socket and runs the handshake.
  static Future<LiveConnection> connect({
    required Uri url,
    required String username,
    required DerivedIdentity identity,
  }) async {
    final channel = IOWebSocketChannel.connect(url);
    final conn = _RealLiveConnection(
      rawStream: channel.stream,
      sink: channel.sink,
      username: username,
      identity: identity,
      channel: channel,
    );
    try {
      await conn._waitForAuth();
    } catch (_) {
      await conn.close();
      rethrow;
    }
    return conn;
  }

  /// Test constructor: drive a synthetic stream + sink. The test is expected
  /// to push `Challenge` (and later `Authenticated`) into the stream; the
  /// returned future resolves once `Authenticated` arrives.
  static Future<LiveConnection> connectForTest({
    required Stream<dynamic> stream,
    required StreamSink<dynamic> sink,
    required String username,
    required DerivedIdentity identity,
  }) async {
    final conn = _RealLiveConnection(
      rawStream: stream,
      sink: sink,
      username: username,
      identity: identity,
    );
    try {
      await conn._waitForAuth();
    } catch (_) {
      await conn.close();
      rethrow;
    }
    return conn;
  }
}

class _RealLiveConnection implements LiveConnection {
  _RealLiveConnection({
    required Stream<dynamic> rawStream,
    required this._sink,
    required this._username,
    required this._identity,
    this._channel,
  }) {
    _incoming = StreamController<RoomServerFrame>.broadcast(
      onListen: _drainBufferLater,
    );
    _sub = rawStream.listen(_enqueue, onDone: _onDone, onError: _onError);
  }

  final StreamSink<dynamic> _sink;
  final WebSocketChannel? _channel;
  final String _username;
  final DerivedIdentity _identity;
  late final StreamController<RoomServerFrame> _incoming;
  late final StreamSubscription<dynamic> _sub;
  final Completer<void> _authReady = Completer<void>();
  final Completer<void> _closedSignal = Completer<void>();
  final List<RoomServerFrame> _buffer = [];
  final List<dynamic> _eventQueue = [];
  bool _processing = false;
  bool _authenticated = false;
  bool _closed = false;

  static const _challengeTag = 'littlelove.v0.2.challenge';

  Future<void> _waitForAuth() => _authReady.future;

  @override
  Stream<RoomServerFrame> get incoming => _incoming.stream;

  @override
  Future<void> get closed => _closedSignal.future;

  void _signalClosed() {
    if (!_closedSignal.isCompleted) _closedSignal.complete();
  }

  @override
  void send(Object payload) {
    if (_closed) return;
    _sink.add(jsonEncode(payload));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _signalClosed();
    if (!_authReady.isCompleted) {
      _authReady.completeError(
        StateError('connection closed before handshake completed'),
      );
    }
    await _sub.cancel();
    if (!_incoming.isClosed) await _incoming.close();
    await _channel?.sink.close();
  }

  void _enqueue(dynamic raw) {
    _eventQueue.add(raw);
    if (!_processing) {
      _processing = true;
      scheduleMicrotask(_drainEventQueue);
    }
  }

  Future<void> _drainEventQueue() async {
    while (_eventQueue.isNotEmpty && !_closed) {
      final raw = _eventQueue.removeAt(0);
      await _onMessage(raw);
    }
    _processing = false;
  }

  Future<void> _onMessage(dynamic raw) async {
    if (raw is! String) return;
    final Map<String, Object?> json;
    try {
      json = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final kind = json['kind'];

    if (!_authenticated) {
      if (kind == 'Challenge') {
        try {
          final nonce = base64.decode(json['nonce']! as String);
          final signingInput = <int>[
            ...utf8.encode(_challengeTag),
            0x00,
            ...nonce,
          ];
          final sig = await _identity.sign(signingInput);
          if (_closed) return;
          _sink.add(
            jsonEncode(
              IdentifyFrame(
                username: _username,
                signatureBase64: base64.encode(sig),
              ).toJson(),
            ),
          );
        } catch (e, st) {
          reportFault(e, st, context: 'auth_challenge');
          if (!_authReady.isCompleted) {
            _authReady.completeError(
              StateError('failed to respond to Challenge: $e'),
            );
          }
        }
      } else if (kind == 'Authenticated') {
        _authenticated = true;
        if (!_authReady.isCompleted) _authReady.complete();
      } else if (kind == 'Error') {
        if (!_authReady.isCompleted) {
          _authReady.completeError(
            StateError(
              'handshake rejected: ${json['code']} ${json['message'] ?? ''}',
            ),
          );
        }
      }
      // Other kinds during auth phase are unexpected; drop.
      return;
    }

    // Post-handshake. Filter any stray auth-phase frames defensively.
    if (kind == 'Challenge' || kind == 'Authenticated') return;
    try {
      final frame = RoomServerFrame.fromJson(json);
      if (_incoming.hasListener) {
        _incoming.add(frame);
      } else {
        // Buffer until somebody subscribes (e.g. RoomMessageRouter).
        _buffer.add(frame);
      }
    } on FormatException catch (_, st) {
      // Drop unknown frames; spec §8.2 enumerates what we recognise. Report a
      // sanitized fault (never the raw frame, which carries ciphertext) so a
      // malformed frame or client/server version skew surfaces.
      reportFault(
        const FormatException('unrecognized room frame'),
        st,
        context: 'room_frame_parse',
      );
    }
  }

  void _drainBufferLater() {
    // Defer one microtask so the listener is fully wired before we feed it.
    scheduleMicrotask(() {
      while (_buffer.isNotEmpty && _incoming.hasListener && !_closed) {
        _incoming.add(_buffer.removeAt(0));
      }
    });
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _signalClosed();
    if (!_authReady.isCompleted) {
      _authReady.completeError(
        StateError('server closed the connection during handshake'),
      );
    }
    if (!_incoming.isClosed) _incoming.close();
  }

  void _onError(Object e, StackTrace _) {
    if (_closed) return;
    _closed = true;
    _signalClosed();
    if (!_authReady.isCompleted) {
      _authReady.completeError(e);
    } else if (!_incoming.isClosed) {
      _incoming.addError(e);
    }
  }
}

/// One live connection per signed-in session. While the network is down,
/// [LiveConnection.connect] throws; we retry with bounded backoff so a queued
/// send flushes the moment the socket returns. Once connected, a socket drop
/// completes [LiveConnection.closed], which re-resolves this provider — that
/// rebuild brings up a fresh socket and rebuilds [outboxDrainProvider], whose
/// constructor auto-drains the persistent outbox.
final liveConnectionProvider = FutureProvider<LiveConnection>((ref) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) {
    throw StateError('no signed-in account — cannot open WSS');
  }
  final identity = await ref.watch(currentIdentityProvider.future);
  final url = ref.watch(serverEndpointProvider).wsConnect;

  var disposed = false;
  ref.onDispose(() => disposed = true);

  var backoff = const Duration(milliseconds: 500);
  const maxBackoff = Duration(seconds: 10);
  while (true) {
    try {
      final conn = await LiveConnection.connect(
        url: url,
        username: account.username,
        identity: identity,
      );
      ref.onDispose(conn.close);
      // Reconnect on an unexpected drop. Guarded so explicit disposal
      // (sign-out / hot-restart) doesn't loop back into a rebuild.
      unawaited(
        conn.closed.then((_) {
          if (!disposed) ref.invalidateSelf();
        }),
      );
      return conn;
    } catch (_) {
      if (disposed) rethrow;
      await Future<void>.delayed(backoff);
      backoff = backoff * 2;
      if (backoff > maxBackoff) backoff = maxBackoff;
    }
  }
});
