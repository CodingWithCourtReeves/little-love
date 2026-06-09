import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

class AppConfig {
  AppConfig({
    required this.username,
    required this.displayName,
    required this.serverUrl,
    required this.contactUsername,
    required this.contactDisplayName,
    this.sharedKeyHex,
  });

  final String username;
  final String displayName;
  final String serverUrl;
  final String contactUsername;
  final String contactDisplayName;

  /// 64 hex chars = 32 bytes. Present from Day-1c onwards.
  final String? sharedKeyHex;

  factory AppConfig.parse(String toml) {
    final doc = TomlDocument.parse(toml).toMap();
    final contact = (doc['contact'] as Map?)?.cast<String, Object?>();
    String require(String key, [Map<String, Object?>? m]) {
      final source = m ?? doc;
      final v = source[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('config: missing or non-string "$key"');
      }
      return v;
    }

    if (contact == null) {
      throw const FormatException('config: missing [contact] table');
    }
    return AppConfig(
      username: require('username'),
      displayName: require('display_name'),
      serverUrl: require('server_url'),
      contactUsername: require('username', contact),
      contactDisplayName: require('display_name', contact),
      sharedKeyHex: doc['shared_key'] as String?,
    );
  }

  /// Returns the OS-appropriate config path. macOS: ~/.littlelove/config.toml.
  /// Windows: %USERPROFILE%\.littlelove\config.toml.
  static File defaultConfigFile() {
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? ''
        : Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      throw StateError('cannot determine home directory');
    }
    return File(p.join(home, '.littlelove', 'config.toml'));
  }

  static Future<AppConfig> load() async {
    final file = defaultConfigFile();
    if (!await file.exists()) {
      throw FileSystemException('config not found; create it at ${file.path}');
    }
    return AppConfig.parse(await file.readAsString());
  }
}
