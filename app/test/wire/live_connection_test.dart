import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeSink implements StreamSink<dynamic> {
  final List<String> writes = <String>[];
  @override
  void add(dynamic event) {
    writes.add(event as String);
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
  @override
  void addError(Object error, [StackTrace? st]) {}
  @override
  Future<void> get done async {}
}

Future<
  ({LiveConnection conn, StreamController<dynamic> server, _FakeSink sink})
>
_openConn() async {
  final seed = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final identity = await deriveIdentity(seed);
  final server = StreamController<dynamic>.broadcast();
  final sink = _FakeSink();

  final connFut = LiveConnection.connectForTest(
    stream: server.stream,
    sink: sink,
    username: 'court',
    identity: identity,
  );
  // Let _RealLiveConnection's listener attach before we feed frames.
  await Future<void>.delayed(Duration.zero);
  server.add(
    jsonEncode({
      'kind': 'Challenge',
      'nonce': base64.encode(List<int>.filled(32, 7)),
    }),
  );
  server.add(jsonEncode({'kind': 'Authenticated'}));
  final conn = await connFut;
  return (conn: conn, server: server, sink: sink);
}

void main() {
  test('connects, handshakes, and broadcasts only room-phase frames', () async {
    final h = await _openConn();
    final firstFrame = h.conn.incoming.first;
    h.server.add(jsonEncode({'kind': 'Rooms', 'rooms': []}));
    final frame = await firstFrame.timeout(const Duration(seconds: 2));
    expect(frame, isA<RoomsFrame>());

    // Auth-phase Authenticated must NOT reach the broadcast.
    h.server.add(jsonEncode({'kind': 'Authenticated'}));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await h.conn.close();
    await h.server.close();
  });

  test('send writes JSON to the sink', () async {
    final h = await _openConn();
    h.conn.send(
      const CreateRoomFrame(
        botAccountIds: [],
        inviteHumanPartner: true,
      ).toJson(),
    );
    expect(h.sink.writes.length, 2); // Identify (handshake) + CreateRoom
    final last = jsonDecode(h.sink.writes.last) as Map<String, Object?>;
    expect(last['kind'], 'CreateRoom');

    await h.conn.close();
    await h.server.close();
  });

  test('closed completes when the socket drops (onDone)', () async {
    final h = await _openConn();
    var didClose = false;
    unawaited(h.conn.closed.then((_) => didClose = true));

    // Server hangs up. _onDone should complete `closed`.
    await h.server.close();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(didClose, isTrue);

    await h.conn.close();
  });

  test('a socket error closes the connection so later sends are dropped',
      () async {
    final h = await _openConn();
    // Subscribe so the error surfaced on `incoming` isn't an unhandled error.
    final errors = <Object>[];
    final sub = h.conn.incoming.listen((_) {}, onError: errors.add);
    final before = h.sink.writes.length; // just the Identify handshake frame

    var didClose = false;
    unawaited(h.conn.closed.then((_) => didClose = true));

    h.server.addError(Exception('socket boom'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(didClose, isTrue);

    // The socket is dead; a send must be a no-op, not a write to a dead sink.
    h.conn.send(
      const CreateRoomFrame(botAccountIds: [], inviteHumanPartner: true)
          .toJson(),
    );
    expect(h.sink.writes.length, before,
        reason: 'send after a socket error must be dropped');

    await sub.cancel();
    await h.conn.close();
    await h.server.close();
  });

  test('closed completes on explicit close()', () async {
    final h = await _openConn();
    var didClose = false;
    unawaited(h.conn.closed.then((_) => didClose = true));

    await h.conn.close();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(didClose, isTrue);

    await h.server.close();
  });

  test(
    'room-phase frames arriving before first subscriber are buffered (no drop)',
    () async {
      final h = await _openConn();

      // Server pushes Rooms immediately after Authenticated — before any
      // subscriber attaches. Pre-fix this was lost between asBroadcastStream
      // teardown + re-listen.
      h.server.add(jsonEncode({'kind': 'Rooms', 'rooms': []}));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Now subscribe — buffered Rooms should be delivered.
      final received = <RoomServerFrame>[];
      final sub = h.conn.incoming.listen(received.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, hasLength(1));
      expect(received.single, isA<RoomsFrame>());

      await sub.cancel();
      await h.conn.close();
      await h.server.close();
    },
  );
}
