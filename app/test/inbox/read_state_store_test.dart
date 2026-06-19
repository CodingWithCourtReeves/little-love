import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('readstate_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('round-trips per-room last-read timestamps', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    expect(await store.load(), isEmpty);

    final t = DateTime.utc(2026, 6, 14, 10, 30);
    await store.save({'room-a': t});

    final loaded = await ReadStateStore(homeDirectory: tmp).load();
    expect(loaded['room-a'], t);
  });

  test('load returns empty map when file is absent', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    expect(await store.load(), isEmpty);
  });

  test('clear removes all saved markers', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    await store.save({'room-a': DateTime.utc(2026, 6, 14)});
    await store.clear();
    expect(await store.load(), isEmpty);
    // Clearing an already-absent file is a no-op, not an error.
    await store.clear();
  });

  test('load returns empty map when file contains corrupt JSON', () async {
    final store = ReadStateStore(homeDirectory: tmp);
    // Seed a file at the store's path, then clobber it with garbage.
    await store.save({'room-a': DateTime.utc(2026, 6, 14, 10, 30)});
    final f = File(p.join(tmp.path, '.littlelove', 'read_state.json'));
    await f.writeAsString('{not valid json');
    expect(await store.load(), isEmpty);
  });
}
