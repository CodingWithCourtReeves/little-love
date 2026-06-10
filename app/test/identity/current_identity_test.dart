import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/identity/keystore.dart';
import 'package:littlelove/identity/providers.dart';

class _CountingKeystore implements Keystore {
  final Map<String, String> _m = {};
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return _m[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _m.remove(key);
  }
}

void main() {
  test('derives identity from keystore seed; caches across reads', () async {
    final seed = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final ks = _CountingKeystore();
    await ks.write('llove.master.court', base64.encode(seed));

    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'unused',
      x25519PubBase64: 'unused',
      createdAt: DateTime.utc(2026, 6, 9),
    );

    final container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(ks),
        accountProvider.overrideWith((_) async => acc),
      ],
    );
    addTearDown(container.dispose);

    final id1 = await container.read(currentIdentityProvider.future);
    final id2 = await container.read(currentIdentityProvider.future);

    expect(
      identical(id1, id2),
      isTrue,
      reason: 'FutureProvider must cache the derived identity',
    );
    expect(
      ks.reads,
      1,
      reason: 'derivation must hit the keystore exactly once per session',
    );

    final expected = await deriveIdentity(seed);
    expect(id1.ed25519PublicKey, expected.ed25519PublicKey);
  });

  test('throws when account is null', () async {
    final container = ProviderContainer(
      overrides: [accountProvider.overrideWith((_) async => null)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(currentIdentityProvider.future),
      throwsA(isA<StateError>()),
    );
  });

  test('throws when keystore seed is missing', () async {
    final ks = _CountingKeystore();
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'x',
      x25519PubBase64: 'x',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    final container = ProviderContainer(
      overrides: [
        keystoreProvider.overrideWithValue(ks),
        accountProvider.overrideWith((_) async => acc),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(currentIdentityProvider.future),
      throwsA(isA<StateError>()),
    );
  });
}
