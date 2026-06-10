// ignore_for_file: implementation_imports
// `package:bip39` re-exports the API but not the wordlist itself.
// Vendoring 2048 words would inflate the diff for zero behavioural benefit;
// the `src/wordlists/english.dart` file is the BIP39 English list with a
// fixed contract (the spec freezes both the words and their order).
import 'dart:typed_data';

import 'package:bip39/src/wordlists/english.dart' show WORDLIST;

/// Spec §8.6 invariants. Mirrors `server/src/invites.rs`.
const int _codeWords = 4;
const int _tokenPrefixLen = 6; // bytes that carry the 44-bit n44
const int _canonicalTokenLen = 32;

class InviteCodeException implements Exception {
  const InviteCodeException(this.message);
  final String message;
  @override
  String toString() => 'InviteCodeException: $message';
}

/// Encode a 32-byte canonical invite token as 4 BIP39 English words joined
/// with `-`. Only the first 6 bytes are read — bytes 6..32 are ignored.
String encodeInviteCode(Uint8List token) {
  if (token.length != _canonicalTokenLen) {
    throw InviteCodeException(
      'token must be $_canonicalTokenLen bytes, got ${token.length}',
    );
  }
  var n48 = 0;
  for (var i = 0; i < _tokenPrefixLen; i++) {
    n48 = (n48 << 8) | token[i];
  }
  final n44 = n48 >> 4;
  final w0 = WORDLIST[(n44 >> 33) & 0x7FF];
  final w1 = WORDLIST[(n44 >> 22) & 0x7FF];
  final w2 = WORDLIST[(n44 >> 11) & 0x7FF];
  final w3 = WORDLIST[n44 & 0x7FF];
  return '$w0-$w1-$w2-$w3';
}

/// Decode a `-`-joined 4-word code to its canonical 32-byte token. The
/// returned bytes match the server's `canonical_token_from_n44(n44)` exactly.
Uint8List decodeInviteCode(String code) {
  final parts = code.trim().toLowerCase().split('-');
  if (parts.length != _codeWords) {
    throw InviteCodeException(
      'expected $_codeWords words, got ${parts.length}',
    );
  }
  final lookup = _indexLookup();
  final indices = <int>[];
  for (final part in parts) {
    final i = lookup[part];
    if (i == null) {
      throw InviteCodeException('unknown BIP39 word: $part');
    }
    indices.add(i);
  }
  final n44 =
      (indices[0] << 33) | (indices[1] << 22) | (indices[2] << 11) | indices[3];
  return canonicalTokenFromN44(n44);
}

/// Build the canonical 32-byte token from a 44-bit value.
Uint8List canonicalTokenFromN44(int n44) {
  assert(n44 >= 0);
  assert(
    n44 >> 44 == 0,
    'n44 must fit in 44 bits, got 0x${n44.toRadixString(16)}',
  );
  final prefix = n44 << 4;
  final out = Uint8List(_canonicalTokenLen);
  out[0] = (prefix >> 40) & 0xFF;
  out[1] = (prefix >> 32) & 0xFF;
  out[2] = (prefix >> 24) & 0xFF;
  out[3] = (prefix >> 16) & 0xFF;
  out[4] = (prefix >> 8) & 0xFF;
  out[5] = prefix & 0xFF;
  return out;
}

Map<String, int>? _lookupCache;
Map<String, int> _indexLookup() {
  final cached = _lookupCache;
  if (cached != null) return cached;
  final m = <String, int>{};
  for (var i = 0; i < WORDLIST.length; i++) {
    m[WORDLIST[i]] = i;
  }
  _lookupCache = m;
  return m;
}
