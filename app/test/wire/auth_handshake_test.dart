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

  test(
    'Identify signature is over the domain-separated input (§8.5.1)',
    () async {
      // Spec §8.5.1 test vector: signing-key seed = 0x01 × 32; nonce = 0x02 × 32.
      final signingSeed = Uint8List.fromList(List<int>.filled(32, 0x01));
      final nonceBytes = Uint8List.fromList(List<int>.filled(32, 0x02));
      final identity = await derivedIdentityFromSigningSeedForTest(signingSeed);
      final server = StreamController<dynamic>();
      final sink = _FakeSink();

      server.add(
        jsonEncode({'kind': 'Challenge', 'nonce': base64.encode(nonceBytes)}),
      );

      final result = await performAuthHandshake(
        stream: server.stream,
        sink: sink,
        username: 'court',
        identity: identity,
        timeout: const Duration(seconds: 2),
        simulateAuthenticatedAfterIdentify: () =>
            server.add(jsonEncode({'kind': 'Authenticated'})),
      );
      expect(result, isA<AuthHandshakeSuccess>());

      final identifyJson =
          jsonDecode(sink.writes.single) as Map<String, Object?>;
      final actualSig = base64.decode(identifyJson['signature']! as String);

      final expectedInput = Uint8List.fromList([
        ...utf8.encode('littlelove.v0.2.challenge'),
        0x00,
        ...nonceBytes,
      ]);
      expect(
        expectedInput.length,
        58,
        reason: 'spec §8.5.1: 25 tag + 1 NUL + 32 nonce = 58 bytes',
      );

      expect(
        await identity.verify(expectedInput, actualSig),
        isTrue,
        reason:
            'signature must verify against the §8.5.1 domain-separated input',
      );

      // Negative control: the same signature must NOT verify against the
      // bare nonce. This guards against the §8.5.1 bug returning.
      expect(
        await identity.verify(nonceBytes, actualSig),
        isFalse,
        reason: 'signature must not verify against the bare nonce',
      );

      await server.close();
    },
  );
}
