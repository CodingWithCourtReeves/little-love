import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  group('ServerFrame.fromJson', () {
    test('parses Challenge frame', () {
      final f = ServerFrame.fromJson(
        jsonDecode('{"kind":"Challenge","nonce":"AAAA"}')
            as Map<String, Object?>,
      );
      expect(f, isA<ChallengeFrame>());
      expect((f as ChallengeFrame).nonceBase64, 'AAAA');
    });

    test('parses Authenticated frame', () {
      final f = ServerFrame.fromJson(
        jsonDecode('{"kind":"Authenticated"}') as Map<String, Object?>,
      );
      expect(f, isA<AuthenticatedFrame>());
    });

    test('parses Error frame with code and message', () {
      final f = ServerFrame.fromJson(
        jsonDecode('{"kind":"Error","code":"InvalidSignature","message":"bad"}')
            as Map<String, Object?>,
      );
      expect(f, isA<ErrorFrame>());
      final e = f as ErrorFrame;
      expect(e.code, 'InvalidSignature');
      expect(e.message, 'bad');
    });

    test('throws on unknown kind', () {
      expect(
        () => ServerFrame.fromJson(<String, Object?>{'kind': 'Nope'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('IdentifyFrame.toJson', () {
    test('emits kind, username, signature', () {
      final f = IdentifyFrame(username: 'court', signatureBase64: 'AAAA');
      final j = f.toJson();
      expect(j['kind'], 'Identify');
      expect(j['username'], 'court');
      expect(j['signature'], 'AAAA');
    });
  });
}
