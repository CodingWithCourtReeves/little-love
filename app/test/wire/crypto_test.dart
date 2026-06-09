import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/crypto.dart';

void main() {
  // Deterministic 32-byte key for tests.
  const keyHex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('round-trip encrypt → decrypt yields the original plaintext', () async {
    final c = SymmetricCipher.fromHex(keyHex);
    final env = await c.encrypt('hey love');
    final out = await c.decrypt(env);
    expect(out, 'hey love');
  });

  test('two encrypts of the same plaintext produce different ciphertexts', () async {
    final c = SymmetricCipher.fromHex(keyHex);
    final a = await c.encrypt('hi');
    final b = await c.encrypt('hi');
    expect(a.ciphertextBase64 == b.ciphertextBase64 && a.nonceBase64 == b.nonceBase64, isFalse);
  });

  test('SymmetricCipher.fromHex throws on wrong-length key', () {
    expect(() => SymmetricCipher.fromHex('abcd'), throwsArgumentError);
  });
}
