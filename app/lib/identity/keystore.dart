import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Identity keystore interface. Two implementations: SecureKeystore (real)
/// and InMemoryKeystore (tests).
abstract class Keystore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class SecureKeystore implements Keystore {
  SecureKeystore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class InMemoryKeystore implements Keystore {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}
