import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/read_state_store.dart';

/// A real store whose [load] waits on a gate, so a test can land a mark while
/// the file is still loading: the window that used to wipe every other room.
class _GatedStore extends ReadStateStore {
  _GatedStore(Directory home, {this.loadError}) : super(homeDirectory: home);

  final Object? loadError;
  final gate = Completer<void>();
  final saves = <Map<String, DateTime>>[];

  @override
  Future<Map<String, DateTime>> load() async {
    await gate.future;
    if (loadError != null) throw loadError!;
    return super.load();
  }

  @override
  Future<void> save(Map<String, DateTime> state) {
    saves.add(state);
    return super.save(state);
  }
}

void main() {
  late Directory tmp;
  final oldMark = DateTime.utc(2026, 10, 30, 19, 56);
  final newMark = DateTime.utc(2026, 11, 4, 12);

  setUp(() => tmp = Directory.systemTemp.createTempSync('rs_hydrate'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer containerWith(ReadStateStore store) {
    final c = ProviderContainer(
      overrides: [readStateStoreProvider.overrideWithValue(store)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> untilSaved(_GatedStore store) async {
    for (var i = 0; i < 2000 && store.saves.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (store.saves.isEmpty) throw StateError('nothing was saved');
    // Let the write itself finish before reading the file back.
    await store.load();
  }

  test('a mark before the file has loaded keeps every other room', () async {
    await ReadStateStore(
      homeDirectory: tmp,
    ).save({'room-a': oldMark, 'room-b': oldMark, 'room-c': oldMark});
    final store = _GatedStore(tmp);
    final c = containerWith(store);

    c.read(readStateProvider.notifier).markRead('room-a');
    expect(store.saves, isEmpty, reason: 'must not save before the load');
    expect(
      c.read(readStateProvider)['room-a'],
      isNotNull,
      reason: 'the mark still applies in memory straight away',
    );

    store.gate.complete();
    await untilSaved(store);

    final reloaded = await ReadStateStore(homeDirectory: tmp).load();
    expect(reloaded.keys, unorderedEquals(['room-a', 'room-b', 'room-c']));
    expect(reloaded['room-a']!.isAfter(oldMark), isTrue);
    expect(reloaded['room-b'], oldMark);
    expect(c.read(readStateProvider), hasLength(3));
  });

  test('loading the file never moves a marker backwards', () async {
    await ReadStateStore(homeDirectory: tmp).save({'room-a': oldMark});
    final store = _GatedStore(tmp);
    final c = containerWith(store);

    c.read(readStateProvider.notifier).markRead('room-a', at: newMark);
    store.gate.complete();
    await untilSaved(store);

    expect(c.read(readStateProvider)['room-a'], newMark);
  });

  test('an older mark before the load cannot beat the saved marker', () async {
    await ReadStateStore(homeDirectory: tmp).save({'room-a': newMark});
    final store = _GatedStore(tmp);
    final c = containerWith(store);

    c.read(readStateProvider.notifier).markRead('room-a', at: oldMark);
    store.gate.complete();
    await untilSaved(store);

    expect(c.read(readStateProvider)['room-a'], newMark);
    final reloaded = await ReadStateStore(homeDirectory: tmp).load();
    expect(reloaded['room-a'], newMark);
  });

  test('a load that throws still lets marks be saved', () async {
    final store = _GatedStore(tmp, loadError: const FileSystemException('x'));
    final c = containerWith(store);

    c.read(readStateProvider.notifier).markRead('room-a', at: newMark);
    store.gate.complete();
    for (var i = 0; i < 2000 && store.saves.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(store.saves, isNotEmpty);
    expect(c.read(readStateProvider)['room-a'], newMark);
  });

  test('a sign-out during the load writes nothing back', () async {
    final store = _GatedStore(tmp);
    final c = containerWith(store);

    c.read(readStateProvider.notifier).markRead('room-a');
    c.invalidate(readStateProvider);
    store.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(store.saves, isEmpty);
  });

  test('marks after the load save straight away, with all rooms', () async {
    await ReadStateStore(
      homeDirectory: tmp,
    ).save({'room-a': oldMark, 'room-b': oldMark});
    final store = _GatedStore(tmp)..gate.complete();
    final c = containerWith(store)..read(readStateProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    c.read(readStateProvider.notifier).markRead('room-a');
    expect(store.saves, hasLength(1));
    expect(store.saves.single.keys, unorderedEquals(['room-a', 'room-b']));
  });
}
