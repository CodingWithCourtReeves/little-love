import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/turn_credentials.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

/// Minimal in-memory LiveConnection: a broadcast incoming stream we can push
/// frames into, plus capture of everything `send` was called with.
class _FakeConn implements LiveConnection {
  final ctrl = StreamController<RoomServerFrame>.broadcast();
  final sent = <Object>[];

  @override
  Stream<RoomServerFrame> get incoming => ctrl.stream;

  @override
  void send(Object payload) => sent.add(payload);

  @override
  Future<void> get closed => Completer<void>().future;

  @override
  Future<void> close() async => ctrl.close();
}

void main() {
  test('CallTurnRequestFrame.toJson has kind and call_id', () {
    expect(const CallTurnRequestFrame(callId: 'c1').toJson(), <String, Object?>{
      'kind': 'CallTurnRequest',
      'call_id': 'c1',
    });
  });

  test('CallTurnGrant parses from json and unwraps iceServers', () {
    final f = RoomServerFrame.fromJson(<String, Object?>{
      'kind': 'CallTurnGrant',
      'call_id': 'c1',
      'ice_servers': <String, Object?>{
        'iceServers': <Object?>[
          <String, Object?>{'urls': 'turn:t', 'username': 'u', 'credential': 'c'},
        ],
      },
    });
    expect(f, isA<CallTurnGrantFrame>());
    final servers = iceServersFromGrant(f as CallTurnGrantFrame);
    expect(servers.single['urls'], 'turn:t');
    expect(servers.single['username'], 'u');
  });

  test('fetchIceServers sends a request and returns the granted servers', () async {
    final conn = _FakeConn();
    final future = fetchIceServers(conn, 'call-1');

    // The request frame is sent synchronously before the first await.
    expect(conn.sent, hasLength(1));
    final sent = conn.sent.single as Map<String, Object?>;
    expect(sent['kind'], 'CallTurnRequest');
    expect(sent['call_id'], 'call-1');

    conn.ctrl.add(
      const CallTurnGrantFrame(
        callId: 'call-1',
        iceServers: <String, Object?>{
          'iceServers': <Object?>[
            <String, Object?>{'urls': 'stun:s'},
            <String, Object?>{
              'urls': 'turn:t',
              'username': 'u',
              'credential': 'c',
            },
          ],
        },
      ),
    );

    final servers = await future;
    expect(servers, hasLength(2));
    expect(servers[1]['urls'], 'turn:t');
    expect(servers[1]['credential'], 'c');
  });

  test('ignores a grant for a different call_id and times out to empty', () async {
    final conn = _FakeConn();
    final future = fetchIceServers(
      conn,
      'call-1',
      timeout: const Duration(milliseconds: 50),
    );

    conn.ctrl.add(
      const CallTurnGrantFrame(
        callId: 'other-call',
        iceServers: <String, Object?>{'iceServers': <Object?>[]},
      ),
    );

    final servers = await future;
    expect(servers, isEmpty);
  });
}
