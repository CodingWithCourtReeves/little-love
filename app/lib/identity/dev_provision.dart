import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_local.dart';
import 'bip39.dart';
import 'keypair.dart';
import 'providers.dart';

/// Dev-only seeded identity, baked at build time by the two-simulator harness
/// (scripts/sim-couple.sh) via `--dart-define`. Empty in any normal build.
///
/// Compile-time (not runtime env) is required because Flutter's
/// `Platform.environment` is empty on iOS — `xcrun simctl launch` env vars never
/// reach Dart. So the harness builds once per partner, baking that partner's
/// username + recovery phrase, and installs each build on its own simulator.
const _devUsername = String.fromEnvironment('LLOVE_DEV_USERNAME');
const _devPhrase = String.fromEnvironment('LLOVE_DEV_PHRASE');

/// When the dev identity is baked in and no local account exists yet, adopt that
/// identity headlessly — the same work [AuthGate]'s sign-in flow does, minus the
/// UI: derive keys from the recovery phrase, stash the seed in the keystore, and
/// write the local account record. The matching server account is created
/// out-of-band by the dev seed tool (server/src/bin/seed_couple.rs), so no
/// signup happens here. No-op in production (the defines are empty, nothing is
/// baked in) and the instant a real account already exists.
Future<void> provisionDevIdentity(ProviderContainer container) async {
  if (_devUsername.isEmpty || _devPhrase.isEmpty) return;

  final store = container.read(accountLocalStoreProvider);
  if (await store.load() != null) return; // already provisioned — idempotent

  final seed = phraseToSeed(_devPhrase.trim());
  final id = await deriveIdentity(seed);
  await container
      .read(keystoreProvider)
      .write('llove.master.$_devUsername', base64.encode(seed));

  // The account is pre-seeded server-side; use its created_at if reachable, else
  // fall back to now (cosmetic — never blocks provisioning in a dev harness).
  var createdAt = DateTime.now().toUtc();
  try {
    final acc = await container
        .read(restClientProvider)
        .getAccountByUsername(_devUsername);
    if (acc != null) createdAt = acc.createdAt;
  } catch (_) {}

  await store.save(
    LocalAccount(
      username: _devUsername,
      ed25519PubBase64: base64.encode(id.ed25519PublicKey),
      x25519PubBase64: base64.encode(id.x25519PublicKey),
      createdAt: createdAt,
    ),
  );
}
