import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class LocalAccount {
  LocalAccount({
    required this.username,
    required this.ed25519PubBase64,
    required this.x25519PubBase64,
    required this.createdAt,
    this.displayName,
    this.avatarPath,
  });

  final String username;
  final String ed25519PubBase64;
  final String x25519PubBase64;
  final DateTime createdAt;

  /// Editable, partner-visible name. Null → fall back to `@username`.
  final String? displayName;

  /// Local filesystem path to my own avatar image (the squared JPEG). Null when
  /// unset. Not synced as a path — only the encrypted blob ref is shared.
  final String? avatarPath;

  LocalAccount copyWith({String? displayName, String? avatarPath}) =>
      LocalAccount(
        username: username,
        ed25519PubBase64: ed25519PubBase64,
        x25519PubBase64: x25519PubBase64,
        createdAt: createdAt,
        displayName: displayName ?? this.displayName,
        avatarPath: avatarPath ?? this.avatarPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'username': username,
    'ed25519_pub': ed25519PubBase64,
    'x25519_pub': x25519PubBase64,
    'created_at': createdAt.toUtc().toIso8601String(),
    if (displayName != null) 'display_name': displayName,
    if (avatarPath != null) 'avatar_path': avatarPath,
  };

  factory LocalAccount.fromJson(Map<String, Object?> json) => LocalAccount(
    username: json['username']! as String,
    ed25519PubBase64: json['ed25519_pub']! as String,
    x25519PubBase64: json['x25519_pub']! as String,
    createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
    displayName: json['display_name'] as String?,
    avatarPath: json['avatar_path'] as String?,
  );
}

class AccountLocalStore {
  AccountLocalStore({Directory? homeDirectory})
    : _home = homeDirectory ?? _defaultHome();

  final Directory _home;

  static Directory _defaultHome() {
    if (Platform.isIOS || Platform.isAndroid) {
      // Sandboxed mobile apps don't reliably receive HOME in their process
      // environment, AND the iOS sandbox container root isn't writable —
      // only Documents/, Library/, and tmp/ subdirs are. Anchor under
      // Documents/, which is the sibling of systemTemp (tmp/).
      return Directory('${Directory.systemTemp.parent.path}/Documents');
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
