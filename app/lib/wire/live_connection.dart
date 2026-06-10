import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../identity/current_identity.dart';
import '../identity/keypair.dart';
import '../identity/providers.dart';
import 'auth_handshake.dart';
import 'frames.dart';

/// Single multiplexed WSS connection for the signed-in session. Owns the
/// socket lifecycle, runs the §8.5.1 handshake, and exposes a broadcast
/// stream of post-handshake room-phase frames plus an outbound JSON sink.
abstract class LiveConnection {
  Stream<RoomServerFrame> get incoming;

  /// Write a client → server frame. `payload` is whatever `Frame.toJson()`
  /// returned.
  void send(Object payload);

  Future<void> close();

  /// Production constructor: opens the socket and runs the handshake.
  static Future<LiveConnection> connect({
    required Uri url,
    required String username,
    required DerivedIdentity identity,
  }) async {
    final channel = IOWebSocketChannel.connect(url);
    final broadcast = channel.stream.asBroadcastStream();
    final result = await performAuthHandshake(
      stream: broadcast,
      sink: channel.sink,
      username: username,
      identity: identity,
    );
    if (result is! AuthHandshakeSuccess) {
      await channel.sink.close();
      throw StateError('WSS handshake failed: $result');
    }
    return _RealLiveConnection(
      rawStream: broadcast,
      sink: channel.sink,
      channel: channel,
    );
  }

  /// Test constructor: drive a synthetic stream + sink. Calls
  /// [simulateAuthenticatedAfterIdentify] the same way
  /// `auth_handshake_test.dart` does so the handshake completes against the
  /// controlled stream.
  static Future<LiveConnection> connectForTest({
    required Stream<dynamic> stream,
    required StreamSink<dynamic> sink,
    required String username,
    required DerivedIdentity identity,
    required void Function() simulateAuthenticatedAfterIdentify,
  }) async {
    final result = await performAuthHandshake(
      stream: stream,
      sink: sink,
      username: username,
      identity: identity,
      simulateAuthenticatedAfterIdentify: simulateAuthenticatedAfterIdentify,
    );
    if (result is! AuthHandshakeSuccess) {
      throw StateError('test handshake failed: $result');
    }
    return _RealLiveConnection(rawStream: stream, sink: sink);
  }
}

class _RealLiveConnection implements LiveConnection {
  _RealLiveConnection({
    required Stream<dynamic> rawStream,
    required this._sink,
    this._channel,
  }) {
    _sub = rawStream.listen(_onMessage, onDone: _onDone, onError: _onError);
  }

  final StreamSink<dynamic> _sink;
  final WebSocketChannel? _channel;
  final StreamController<RoomServerFrame> _incoming =
      StreamController<RoomServerFrame>.broadcast();
  late final StreamSubscription<dynamic> _sub;
  bool _closed = false;

  @override
  Stream<RoomServerFrame> get incoming => _incoming.stream;

  @override
  void send(Object payload) {
    if (_closed) return;
    _sink.add(jsonEncode(payload));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _incoming.close();
    await _channel?.sink.close();
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, Object?> json;
    try {
      json = jsonDecode(raw) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    final kind = json['kind'];
    // Auth-phase frames must not leak into the room-phase broadcast.
    if (kind == 'Challenge' || kind == 'Authenticated') return;
    try {
      _incoming.add(RoomServerFrame.fromJson(json));
    } on FormatException {
      // Drop unknown frames; spec §8.2 enumerates the kinds we recognise.
    }
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    _incoming.close();
  }

  void _onError(Object e, StackTrace _) {
    _incoming.addError(e);
  }
}

/// One live connection per signed-in session. Errors / null account propagate
/// as `AsyncError` / `AsyncLoading`; widgets handle via `.when`.
final liveConnectionProvider = FutureProvider<LiveConnection>((ref) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) {
    throw StateError('no signed-in account — cannot open WSS');
  }
  final identity = await ref.watch(currentIdentityProvider.future);
  final url = ref.watch(serverEndpointProvider).wsConnect;
  final conn = await LiveConnection.connect(
    url: url,
    username: account.username,
    identity: identity,
  );
  ref.onDispose(conn.close);
  return conn;
});
