import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/live_pairing_transport.dart';

class _FakeSink implements StreamSink<dynamic> {
  final List<String> writes = <String>[];
  @override
  void add(dynamic event) => writes.add(event as String);
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
_harness() async {
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
  test(
    'createInvite writes CreateRoom, returns InviteCreated from RoomCreated.pending_invite',
    () async {
      final h = await _harness();
      addTearDown(h.conn.close);
      final transport = LivePairingTransport(h.conn);

      final fut = transport.createInvite();
      await Future<void>.delayed(Duration.zero);
      final sent = jsonDecode(h.sink.writes.last) as Map<String, Object?>;
      expect(sent['kind'], 'CreateRoom');
      expect(sent['invite_human_partner'], true);

      h.server.add(
        jsonEncode({
          'kind': 'RoomCreated',
          'room_id': '01JROOM',
          'name': '',
          'members': [
            {'username': 'court', 'ed25519_pub': 'AAAA', 'x25519_pub': 'BBBB'},
          ],
          'pending_invite': {
            'code': 'amber-fern-locket-tide',
            'qr_png_base64': 'AAAA',
            'expires_at': '2026-06-09T20:32:00Z',
          },
        }),
      );
      final created = await fut.timeout(const Duration(seconds: 2));
      expect(created.code, 'amber-fern-locket-tide');
      await h.server.close();
    },
  );

  test('consumeInvite returns next InviteConsumed', () async {
    final h = await _harness();
    addTearDown(h.conn.close);
    final transport = LivePairingTransport(h.conn);

    final fut = transport.consumeInvite(
      code: 'amber-fern-locket-tide',
      signature: Uint8List(64),
    );
    await Future<void>.delayed(Duration.zero);
    final sent = jsonDecode(h.sink.writes.last) as Map<String, Object?>;
    expect(sent['kind'], 'ConsumeInvite');
    expect(sent['code'], 'amber-fern-locket-tide');

    h.server.add(
      jsonEncode({
        'kind': 'InviteConsumed',
        'room_id': '01JROOMID',
        'name': '',
        'members': [
          {'username': 'court', 'ed25519_pub': 'AAAA', 'x25519_pub': 'BBBB'},
        ],
      }),
    );
    final consumed = await fut.timeout(const Duration(seconds: 2));
    expect(consumed.roomId, '01JROOMID');
    await h.server.close();
  });

  test('RoomError from server surfaces as PairingTransportException', () async {
    final h = await _harness();
    addTearDown(h.conn.close);
    final transport = LivePairingTransport(h.conn);

    final fut = transport.createInvite();
    await Future<void>.delayed(Duration.zero);
    h.server.add(
      jsonEncode({'kind': 'Error', 'code': 'AlreadyPaired', 'message': 'no'}),
    );
    await expectLater(fut, throwsA(isA<PairingTransportException>()));
    await h.server.close();
  });

  test('two concurrent createInvite calls each get the right reply', () async {
    final h = await _harness();
    addTearDown(h.conn.close);
    final transport = LivePairingTransport(h.conn);

    final a = transport.createInvite();
    final b = transport.createInvite();
    await Future<void>.delayed(Duration.zero);

    h.server.add(
      jsonEncode({
        'kind': 'InviteCreated',
        'code': 'aaa-bbb-ccc-ddd',
        'qr_png_base64': 'AAAA',
        'expires_at': '2026-06-09T20:32:00Z',
      }),
    );
    h.server.add(
      jsonEncode({
        'kind': 'InviteCreated',
        'code': 'eee-fff-ggg-hhh',
        'qr_png_base64': 'AAAA',
        'expires_at': '2026-06-09T20:32:00Z',
      }),
    );

    final ra = await a.timeout(const Duration(seconds: 2));
    final rb = await b.timeout(const Duration(seconds: 2));
    expect(ra.code, 'aaa-bbb-ccc-ddd');
    expect(rb.code, 'eee-fff-ggg-hhh');
    await h.server.close();
  });
}
