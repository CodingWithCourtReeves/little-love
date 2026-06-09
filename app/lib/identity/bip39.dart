import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;

// Spec §3.1.2 says "256-bit entropy" but §3.1.3 and the rest of the spec /
// brief / acceptance criteria pin the user contract at a 12-word phrase.
// BIP39 12 words = 128-bit entropy. We follow the user contract; §3.1.2 is
// a pending spec amendment ("256-bit" → "128-bit").
const _seedLengthBytes = 16;

/// Generate 16 bytes (128 bits) of seed entropy via the OS CSPRNG.
Uint8List generateSeed() {
  final rng = Random.secure();
  final bytes = Uint8List(_seedLengthBytes);
  for (var i = 0; i < _seedLengthBytes; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}

/// Encode a 16-byte seed as a 12-word BIP39 English phrase.
String seedToPhrase(Uint8List seed) {
  if (seed.length != _seedLengthBytes) {
    throw ArgumentError('seed must be $_seedLengthBytes bytes, got ${seed.length}');
  }
  final hex = seed
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return bip39.entropyToMnemonic(hex);
}

/// Decode a 12-word BIP39 phrase back to a 16-byte seed.
Uint8List phraseToSeed(String phrase) {
  final words = phrase.trim().split(RegExp(r'\s+'));
  if (words.length != 12) {
    throw FormatException(
      'phrase must be exactly 12 words, got ${words.length}',
    );
  }
  if (!bip39.validateMnemonic(phrase)) {
    throw const FormatException('phrase contains invalid words or checksum');
  }
  final hex = bip39.mnemonicToEntropy(phrase);
  return Uint8List.fromList(
    [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ],
  );
}
