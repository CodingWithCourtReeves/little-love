import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/encryption.dart';

Uint8List _key(int byte) => Uint8List(32)..fillRange(0, 32, byte);

void main() {
  group('Message encryption (spec §5.2 / §13 AC #3)', () {
    test('round-trip: encrypt then decrypt returns the plaintext', () async {
      final key = _key(0xAB);
      final wire = await encryptOutgoing(key, 'hello love');
      final plain = await decryptIncoming(key, wire);
      expect(plain, 'hello love');
    });

    test('wrong key returns the cannot-decrypt sentinel', () async {
      final wire = await encryptOutgoing(_key(0xAB), 'top secret');
      final out = await decryptIncoming(_key(0xCD), wire);
      expect(out, cannotDecryptSentinel);
    });

    test('garbage wire body returns the cannot-decrypt sentinel', () async {
      final out = await decryptIncoming(_key(0xAB), 'not-a-wire-body');
      expect(out, cannotDecryptSentinel);
    });

    test('two encrypts of the same plaintext produce different ciphertexts',
        () async {
      final key = _key(0xAB);
      final a = await encryptOutgoing(key, 'hi');
      final b = await encryptOutgoing(key, 'hi');
      expect(
        a,
        isNot(equals(b)),
        reason: 'XChaCha20-Poly1305 nonce must be fresh per call',
      );
    });
  });
}
