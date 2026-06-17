import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/file_crypto.dart';

void main() {
  test('encrypt then decrypt round-trips arbitrary bytes', () async {
    final plain = Uint8List.fromList(List<int>.generate(5000, (i) => i % 256));
    final enc = await encryptFileBytes(plain);
    expect(enc.key.length, 32);
    expect(enc.nonce.length, 24);
    expect(enc.ciphertext.length, greaterThan(plain.length)); // + 16-byte MAC

    final out = await decryptFileBytes(
      key: enc.key,
      nonce: enc.nonce,
      ciphertext: enc.ciphertext,
    );
    expect(out, equals(plain));
  });

  test('wrong key fails to decrypt', () async {
    final plain = Uint8List.fromList([1, 2, 3, 4]);
    final enc = await encryptFileBytes(plain);
    final badKey = Uint8List(32)..[0] = 0xFF;
    expect(
      () => decryptFileBytes(
        key: badKey,
        nonce: enc.nonce,
        ciphertext: enc.ciphertext,
      ),
      throwsA(isA<Exception>()),
    );
  });
}
