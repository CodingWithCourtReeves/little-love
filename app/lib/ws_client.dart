import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'wire/message.dart';

/// Simple ramped backoff schedule for reconnect attempts.
class LinearBackoff {
  static const _steps = [1, 2, 5, 10, 15];
  int _i = 0;

  Duration next() {
    final s = _steps[_i.clamp(0, _steps.length - 1)];
    if (_i < _steps.length - 1) _i++;
    return Duration(seconds: s);
  }

  void reset() => _i = 0;
}

class WsClient {
  WsClient({
    required this.url,
    required this.username,
  });

  final String url;
  final String username;

  final _backoff = LinearBackoff();
  final _incoming = StreamController<Msg>.broadcast();
  Stream<Msg> get incoming => _incoming.stream;

  WebSocketChannel? _channel;
  bool _closed = false;

  Future<void> start() async {
    while (!_closed) {
      try {
        _channel = IOWebSocketChannel.connect(
          Uri.parse(url),
          headers: {'x-llove-user': username},
        );
        _backoff.reset();
        await for (final raw in _channel!.stream) {
          if (raw is! String) continue;
          final json = jsonDecode(raw) as Map<String, Object?>;
          if (json['type'] != 'msg') continue;
          _incoming.add(Msg.fromJson(json));
        }
      } catch (_) {
        // fall through to backoff
      }
      if (_closed) break;
      await Future<void>.delayed(_backoff.next());
    }
  }

  void send(Msg msg) {
    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  Future<void> close() async {
    _closed = true;
    await _channel?.sink.close();
    await _incoming.close();
  }
}
