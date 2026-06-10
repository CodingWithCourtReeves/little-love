import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/bip39_invite.dart';

Uint8List _hexDecode(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hexEncode(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void main() {
  group('BIP39 invite encoding', () {
    final fixturePath = '../server/tests/data/invite_vectors.json';

    test('matches the cross-language fixture byte-for-byte', () {
      final file = File(fixturePath);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'fixture missing — WT-B should have committed it',
      );
      final vectors = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      expect(vectors, isNotEmpty);
      for (final v in vectors) {
        final m = v as Map<String, Object?>;
        final canonicalHex = m['canonical_token_hex']! as String;
        final code = m['code']! as String;
        final canonical = _hexDecode(canonicalHex);
        expect(
          encodeInviteCode(canonical),
          code,
          reason: 'encode mismatch for $canonicalHex',
        );
        final decoded = decodeInviteCode(code);
        expect(
          _hexEncode(decoded),
          canonicalHex,
          reason: 'decode mismatch for $code',
        );
      }
    });

    test('decode rejects wrong word count', () {
      expect(
        () => decodeInviteCode('abandon-abandon-abandon'),
        throwsA(isA<InviteCodeException>()),
      );
      expect(
        () => decodeInviteCode('abandon-abandon-abandon-abandon-abandon'),
        throwsA(isA<InviteCodeException>()),
      );
    });

    test('decode rejects unknown word', () {
      expect(
        () => decodeInviteCode('abandon-abandon-abandon-bogusword'),
        throwsA(isA<InviteCodeException>()),
      );
    });

    test('decode is case-insensitive and trims surrounding whitespace', () {
      final lower = decodeInviteCode('abandon-abandon-abandon-ability');
      final upper = decodeInviteCode('  ABANDON-Abandon-abANDon-ABILITY  ');
      expect(_hexEncode(lower), _hexEncode(upper));
    });
  });
}
