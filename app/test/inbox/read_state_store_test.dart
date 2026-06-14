import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/read_state_store.dart';

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
}
