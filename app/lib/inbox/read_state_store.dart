import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/crash_reporting.dart';

/// Per-device persistence of the last-read message timestamp per room.
/// Mirrors [AccountLocalStore]'s home-anchored JSON pattern so it works in
/// the iOS/Android sandbox (writes under Documents/) and on desktop (~).
///
/// This file is a cache of the unread markers. The server's `read_at` is the
/// durable record and restores them on every connect ([ReadMarkerFrame]), so
/// losing the file costs at most a moment of wrong counts.
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

  File get _tempFile => File('${_file.path}.tmp');

  /// The tail of the operation queue. Saves are fire-and-forget and a chat open
  /// makes two in a row, so without this they overlap on the same temp file and
  /// a load can run in the middle of one.
  Future<void> _tail = Future<void>.value();

  /// Set by [clear]; saves after that are dropped.
  bool _closed = false;

  /// Run [op] after everything already queued. A failed [op] reaches its own
  /// caller but must not stop the operations behind it.
  Future<T> _enqueue<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, DateTime>> load() => _enqueue(_read);

  /// Write [state] to a temp file and rename it over the markers, so the file is
  /// complete at every moment. Writing in place empties it first: a kill or a
  /// load in that gap lost every room's marker, and the next save made the loss
  /// permanent, leaving each room's messages counted as unread.
  Future<void> save(Map<String, DateTime> state) {
    if (_closed) return Future<void>.value();
    return _enqueue(() => _write(state));
  }

  Future<void> _write(Map<String, DateTime> state) async {
    final f = _file;
    await f.parent.create(recursive: true);
    final raw = state.map((k, v) => MapEntry(k, v.toUtc().toIso8601String()));
    final temp = _tempFile;
    await temp.writeAsString(jsonEncode(raw), flush: true);
    await temp.rename(f.path);
  }

  /// Drop all saved read markers (used on sign-out so a new account on this
  /// device doesn't inherit the previous user's read state). Also closes this
  /// instance to further saves: the socket stays up for the rest of sign-out, so
  /// a mark landing in that gap would otherwise write the markers back. Sign-out
  /// invalidates the provider so the next account gets a new instance.
  Future<void> clear() {
    _closed = true;
    return _enqueue(() async {
      for (final f in [_file, _tempFile]) {
        if (await f.exists()) await f.delete();
      }
    });
  }

  Future<Map<String, DateTime>> _read() async {
    final f = _file;
    if (!await f.exists()) return <String, DateTime>{};
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      return raw.map(
        (k, v) => MapEntry(k, DateTime.parse(v! as String).toUtc()),
      );
    } catch (_, st) {
      // Corrupt or partially-written file — treat as no saved state. Report a
      // sanitized fault (the raw decode error can embed a handle from the file).
      reportFault(
        const FormatException('corrupt read_state.json'),
        st,
        context: 'read_state_load',
      );
      return <String, DateTime>{};
    }
  }
}
