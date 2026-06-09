import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keypair.dart';

void main() {
  final fixedSeed = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

  test('deriveMasterSecret produces 32 bytes', () async {
    final master = await deriveMasterSecret(fixedSeed);
    expect(master.length, 32);
  });

  test('deriveIdentity is deterministic across two calls', () async {
    final a = await deriveIdentity(fixedSeed);
    final b = await deriveIdentity(fixedSeed);
    expect(a.ed25519PublicKey, equals(b.ed25519PublicKey));
    expect(a.x25519PublicKey, equals(b.x25519PublicKey));
  });

  test('deriveIdentity public keys are each 32 bytes', () async {
    final id = await deriveIdentity(fixedSeed);
    expect(id.ed25519PublicKey.length, 32);
    expect(id.x25519PublicKey.length, 32);
  });

  test('different seeds yield different keys', () async {
    final a = await deriveIdentity(fixedSeed);
    final other = Uint8List.fromList(List<int>.generate(16, (i) => 99 - i));
    final b = await deriveIdentity(other);
    expect(a.ed25519PublicKey == b.ed25519PublicKey, isFalse);
  });

  test('signing with derived key verifies', () async {
    final id = await deriveIdentity(fixedSeed);
    final msg = Uint8List.fromList([1, 2, 3, 4, 5]);
    final sig = await id.sign(msg);
    expect(sig.length, 64);
    expect(await id.verify(msg, sig), isTrue);
    expect(await id.verify(Uint8List.fromList([9, 9, 9]), sig), isFalse);
  });
}
