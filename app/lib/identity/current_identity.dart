import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'keypair.dart';
import 'providers.dart';

/// One-derivation-per-session provider for the signed-in user's
/// `DerivedIdentity`. Reads the seed from the keystore exactly once and
/// caches the derived keypair for the lifetime of the `ProviderContainer`.
final currentIdentityProvider = FutureProvider<DerivedIdentity>((ref) async {
  final account = await ref.watch(accountProvider.future);
  if (account == null) {
    throw StateError('no signed-in account');
  }
  final keystore = ref.watch(keystoreProvider);
  final seedB64 = await keystore.read('llove.master.${account.username}');
  if (seedB64 == null) {
    throw StateError('keystore is missing master seed for ${account.username}');
  }
  final seed = Uint8List.fromList(base64.decode(seedB64));
  return deriveIdentity(seed);
});
