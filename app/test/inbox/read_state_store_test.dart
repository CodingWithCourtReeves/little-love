import 'dart:convert';
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

  group('a save can never damage the saved markers', () {
    File markerFile() =>
        File(p.join(tmp.path, '.littlelove', 'read_state.json'));

    Map<String, DateTime> markers(int rooms, {int second = 0}) => {
      for (var i = 0; i < rooms; i++)
        'room-$i': DateTime.utc(2026, 11, 4, 12, i, second),
    };

    test('the file is complete at every moment during a save', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      await store.save(markers(22));
      // Read the file directly, as a kill mid-save would leave it: going through
      // the store would hide a truncated file behind its own write queue.
      for (var i = 0; i < 300; i++) {
        final write = store.save(markers(22));
        final raw = await markerFile().readAsString();
        await write;
        expect(raw, isNotEmpty, reason: 'iteration $i saw an emptied file');
        expect((jsonDecode(raw) as Map).length, 22);
      }
    });

    test('overlapping saves end on the newest state, as valid JSON', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      for (var run = 0; run < 40; run++) {
        final writes = <Future<void>>[
          for (var rooms = 1; rooms <= 22; rooms++)
            store.save(markers(rooms, second: run)),
        ];
        await Future.wait(writes);
        final saved = jsonDecode(await markerFile().readAsString()) as Map;
        expect(saved.length, 22, reason: 'run $run');
      }
    });

    test('a load waits for a save already in flight', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      await store.save(markers(1));
      final write = store.save(markers(22));
      expect(await store.load(), hasLength(22));
      await write;
    });

    test('a leftover temp file from a killed save is ignored', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      await store.save(markers(3));
      await File('${markerFile().path}.tmp').writeAsString('{"room-0":"tru');
      expect(await store.load(), hasLength(3));
      await store.save(markers(4));
      expect(await store.load(), hasLength(4));
    });

    test('a failed save does not block the saves after it', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      // A file where the folder belongs makes the next save fail.
      final blocker = File(p.join(tmp.path, '.littlelove'));
      await blocker.writeAsString('');
      await expectLater(store.save(markers(1)), throwsA(anything));
      await blocker.delete();
      await store.save(markers(2));
      expect(await store.load(), hasLength(2));
    });

    test('a save after clear is dropped (sign-out cannot resurrect)', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      await store.save(markers(3));
      await store.clear();
      // A frame landing while sign-out finishes its other steps marks a room.
      await store.save(markers(3));
      expect(await markerFile().exists(), isFalse);
      expect(await store.load(), isEmpty);
    });

    test('clear removes a leftover temp file too', () async {
      final store = ReadStateStore(homeDirectory: tmp);
      await store.save(markers(1));
      final leftover = File('${markerFile().path}.tmp');
      await leftover.writeAsString('{}');
      await store.clear();
      expect(await leftover.exists(), isFalse);
    });
  });
}
