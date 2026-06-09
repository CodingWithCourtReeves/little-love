import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/wire/auth_handshake.dart';

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

void main() {
  final seed = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  test('successful handshake returns AuthHandshakeSuccess', () async {
    final identity = await deriveIdentity(seed);
    final server = StreamController<dynamic>();
    final sink = _FakeSink();

    server.add(
      jsonEncode({
        'kind': 'Challenge',
        'nonce': base64.encode(List<int>.filled(32, 7)),
      }),
    );

    final result = await performAuthHandshake(
      stream: server.stream,
      sink: sink,
      username: 'court',
      identity: identity,
      timeout: const Duration(seconds: 5),
      simulateAuthenticatedAfterIdentify: () =>
          server.add(jsonEncode({'kind': 'Authenticated'})),
    );

    expect(result, isA<AuthHandshakeSuccess>());
    expect(sink.writes.length, 1);
    final ident = jsonDecode(sink.writes.single) as Map<String, Object?>;
    expect(ident['kind'], 'Identify');
    expect(ident['username'], 'court');
    expect(ident['signature'], isA<String>());
    await server.close();
  });

  test('server Error frame returns AuthHandshakeFailure with code', () async {
    final identity = await deriveIdentity(seed);
    final server = StreamController<dynamic>();
    final sink = _FakeSink();

    server.add(
      jsonEncode({
        'kind': 'Challenge',
        'nonce': base64.encode(List<int>.filled(32, 7)),
      }),
    );

    final result = await performAuthHandshake(
      stream: server.stream,
      sink: sink,
      username: 'court',
      identity: identity,
      timeout: const Duration(seconds: 5),
      simulateAuthenticatedAfterIdentify: () => server.add(
        jsonEncode({
          'kind': 'Error',
          'code': 'InvalidSignature',
          'message': 'no',
        }),
      ),
    );

    expect(result, isA<AuthHandshakeFailure>());
    expect((result as AuthHandshakeFailure).code, 'InvalidSignature');
    await server.close();
  });

  test('timeout returns AuthHandshakeFailure', () async {
    final identity = await deriveIdentity(seed);
    final server = StreamController<dynamic>();
    final sink = _FakeSink();
    final result = await performAuthHandshake(
      stream: server.stream,
      sink: sink,
      username: 'court',
      identity: identity,
      timeout: const Duration(milliseconds: 50),
    );
    expect(result, isA<AuthHandshakeFailure>());
    expect((result as AuthHandshakeFailure).code, 'Timeout');
    await server.close();
  });
}
