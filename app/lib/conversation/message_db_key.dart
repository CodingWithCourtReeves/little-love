import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mints (once) and loads the per-device SQLCipher key for the local message
/// store. The key never leaves the device: stored in the iOS keychain with
/// `first_unlock_this_device`, never synced or escrowed. The DB it protects is
/// a rebuildable projection of the server's ciphertext, so losing the key (e.g.
/// keychain wipe) is recoverable — the store re-seeds from a full replay.
class MessageDbKey {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _name = 'llove.msgdb.key';

  /// Returns the base64 key, minting a fresh 32-byte random key on first use.
  static Future<String> loadOrCreate() async {
    final existing = await _storage.read(key: _name);
    if (existing != null) return existing;
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = base64.encode(bytes);
    await _storage.write(key: _name, value: key);
    return key;
  }
}
