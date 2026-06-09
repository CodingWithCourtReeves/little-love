import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

const _masterSalt = 'littlelove.v0.2.master';
const _signingSalt = 'littlelove.v0.2.signing';
const _encryptionSalt = 'littlelove.v0.2.encryption';

Future<Uint8List> _hkdf(
  Uint8List ikm, {
  required String salt,
  int length = 32,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  // spec §3.1.5 does not specify info; default = empty bytes.
  final out = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: utf8.encode(salt),
  );
  final bytes = await out.extractBytes();
  return Uint8List.fromList(bytes);
}

Future<Uint8List> deriveMasterSecret(Uint8List seed) {
  return _hkdf(seed, salt: _masterSalt);
}

class DerivedIdentity {
  DerivedIdentity._({
    required this.ed25519PublicKey,
    required this.x25519PublicKey,
    required SimpleKeyPair signingKeyPair,
    required this.encryptionKeyPair,
  }) : _signingKeyPair = signingKeyPair; // ignore: prefer_initializing_formals

  /// Raw 32-byte Ed25519 public key.
  final Uint8List ed25519PublicKey;

  /// Raw 32-byte X25519 public key.
  final Uint8List x25519PublicKey;

  final SimpleKeyPair _signingKeyPair;

  /// X25519 keypair retained so WT-D can compute ECDH against a peer pubkey.
  final SimpleKeyPair encryptionKeyPair;

  Future<Uint8List> sign(List<int> message) async {
    final sig = await Ed25519().sign(message, keyPair: _signingKeyPair);
    return Uint8List.fromList(sig.bytes);
  }

  Future<bool> verify(List<int> message, List<int> signature) async {
    final pub = SimplePublicKey(ed25519PublicKey, type: KeyPairType.ed25519);
    return Ed25519().verify(
      message,
      signature: Signature(signature, publicKey: pub),
    );
  }
}

Future<DerivedIdentity> deriveIdentity(Uint8List seed) async {
  final master = await deriveMasterSecret(seed);
  final signingSeed = await _hkdf(master, salt: _signingSalt);
  final encryptionSeed = await _hkdf(master, salt: _encryptionSalt);

  final signingKeyPair = await Ed25519().newKeyPairFromSeed(signingSeed);
  final signingPub = await signingKeyPair.extractPublicKey();

  final encryptionKeyPair = await X25519().newKeyPairFromSeed(encryptionSeed);
  final encryptionPub = await encryptionKeyPair.extractPublicKey();

  return DerivedIdentity._(
    ed25519PublicKey: Uint8List.fromList(signingPub.bytes),
    x25519PublicKey: Uint8List.fromList(encryptionPub.bytes),
    signingKeyPair: signingKeyPair,
    encryptionKeyPair: encryptionKeyPair,
  );
}

/// Build a DerivedIdentity directly from a 32-byte Ed25519 signing seed,
/// bypassing BIP39/HKDF. Tests only — production identities always flow
/// through [deriveIdentity] starting from a 16-byte BIP39 seed so the spec
/// §8.5.1 vector (which fixes the signing seed) can be asserted byte-for-byte.
/// The encryption keypair is derived from the same seed bytes so the
/// returned object is consistent, but no test should depend on its content.
@visibleForTesting
Future<DerivedIdentity> derivedIdentityFromSigningSeedForTest(
  Uint8List signingSeed32,
) async {
  if (signingSeed32.length != 32) {
    throw ArgumentError(
      'signing seed must be 32 bytes, got ${signingSeed32.length}',
    );
  }
  final signingKeyPair = await Ed25519().newKeyPairFromSeed(signingSeed32);
  final signingPub = await signingKeyPair.extractPublicKey();
  final encryptionKeyPair = await X25519().newKeyPairFromSeed(signingSeed32);
  final encryptionPub = await encryptionKeyPair.extractPublicKey();
  return DerivedIdentity._(
    ed25519PublicKey: Uint8List.fromList(signingPub.bytes),
    x25519PublicKey: Uint8List.fromList(encryptionPub.bytes),
    signingKeyPair: signingKeyPair,
    encryptionKeyPair: encryptionKeyPair,
  );
}
