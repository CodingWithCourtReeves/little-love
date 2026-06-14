import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-device persistence of the last-read message timestamp per room.
/// Mirrors [AccountLocalStore]'s home-anchored JSON pattern so it works in
/// the iOS/Android sandbox (writes under Documents/) and on desktop (~).
///
/// Read state is intentionally local-only (spec: v0.4 does not sync read
/// markers across a user's devices).
class ReadStateStore {
  ReadStateStore({Directory? homeDirectory})
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

  File get _file => File(p.join(_home.path, '.littlelove', 'read_state.json'));

  Future<Map<String, DateTime>> load() async {
    final f = _file;
    if (!await f.exists()) return <String, DateTime>{};
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      return raw.map(
        (k, v) => MapEntry(k, DateTime.parse(v! as String).toUtc()),
      );
    } catch (_) {
      // Corrupt or partially-written file — treat as no saved state.
      return <String, DateTime>{};
    }
  }

  Future<void> save(Map<String, DateTime> state) async {
    final f = _file;
    await f.parent.create(recursive: true);
    final raw = state.map(
      (k, v) => MapEntry(k, v.toUtc().toIso8601String()),
    );
    await f.writeAsString(jsonEncode(raw));
  }
}
