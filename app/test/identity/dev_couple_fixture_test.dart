import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/bip39.dart';
import 'package:littlelove/identity/keypair.dart';

/// Guards `scripts/dev-couple.json` — the fixture shared by the two-simulator
/// harness (scripts/sim-couple.sh) and the dev seed tool
/// (server/src/bin/seed_couple.rs). The harness gives each simulator a phrase;
/// the seed tool inserts the matching pubkeys into the dev DB. If the client's
/// key derivation ever changes, the committed pubkeys would no longer match what
/// a client derives from the phrase — E2EE/auth would silently break. This test
/// re-derives from the committed phrases and asserts the pubkeys still hold.
void main() {
  test('committed dev-couple pubkeys match what the phrases derive', () async {
    final file = File('../scripts/dev-couple.json');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'run the generator in the spec, or restore scripts/dev-couple.json',
    );
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

    for (final user in ['court', 'kaitlyn']) {
      final entry = fixture[user] as Map<String, Object?>;
      final seed = phraseToSeed(entry['phrase'] as String);
      final id = await deriveIdentity(seed);
      expect(
        base64.encode(id.ed25519PublicKey),
        entry['ed25519_pub'],
        reason: '$user ed25519_pub drift — regenerate the fixture',
      );
      expect(
        base64.encode(id.x25519PublicKey),
        entry['x25519_pub'],
        reason: '$user x25519_pub drift — regenerate the fixture',
      );
    }
  });
}
