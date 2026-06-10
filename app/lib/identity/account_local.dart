import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class LocalAccount {
  LocalAccount({
    required this.username,
    required this.ed25519PubBase64,
    required this.x25519PubBase64,
    required this.createdAt,
  });

  final String username;
  final String ed25519PubBase64;
  final String x25519PubBase64;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'username': username,
    'ed25519_pub': ed25519PubBase64,
    'x25519_pub': x25519PubBase64,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory LocalAccount.fromJson(Map<String, Object?> json) => LocalAccount(
    username: json['username']! as String,
    ed25519PubBase64: json['ed25519_pub']! as String,
    x25519PubBase64: json['x25519_pub']! as String,
    createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
  );
}

class AccountLocalStore {
  AccountLocalStore({Directory? homeDirectory})
    : _home = homeDirectory ?? _defaultHome();

  final Directory _home;

  static Directory _defaultHome() {
    if (Platform.isIOS || Platform.isAndroid) {
      // Sandboxed mobile apps don't reliably receive HOME in their process
      // environment. The sandbox container (parent of the per-app tmp dir)
      // is writable and persists across launches, so anchor ~/.littlelove
      // there. Equivalent to NSHomeDirectory() on iOS.
      return Directory.systemTemp.parent;
    }
    final home = Platform.isWindows
        ? Platform.environment['USERPROFILE'] ?? ''
        : Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      throw StateError('cannot determine home directory');
    }
    return Directory(home);
  }

  File get _file => File(p.join(_home.path, '.littlelove', 'account.json'));

  Future<LocalAccount?> load() async {
    final f = _file;
    if (!await f.exists()) return null;
    final json = jsonDecode(await f.readAsString()) as Map<String, Object?>;
    return LocalAccount.fromJson(json);
  }

  Future<void> save(LocalAccount acc) async {
    final f = _file;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(acc.toJson()));
  }

  Future<void> delete() async {
    final f = _file;
    if (await f.exists()) await f.delete();
  }
}
