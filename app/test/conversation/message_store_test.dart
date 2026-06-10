import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/wire/message.dart';

Msg _msg(String id, String body) => Msg(
  id: id,
  from: 'court',
  to: 'kaitlyn',
  body: body,
  ts: DateTime.utc(2026, 6, 9, 17, 0),
);

void main() {
  test('initial buffer is empty', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(messageStoreProvider('roomA')), isEmpty);
  });

  test('add appends in arrival order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(messageStoreProvider('roomA').notifier).add(_msg('1', 'hi'));
    container
        .read(messageStoreProvider('roomA').notifier)
        .add(_msg('2', 'there'));
    final out = container.read(messageStoreProvider('roomA'));
    expect(out.map((m) => m.body).toList(), ['hi', 'there']);
  });

  test('different roomIds have independent buffers', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(messageStoreProvider('roomA').notifier)
        .add(_msg('1', 'in A'));
    container
        .read(messageStoreProvider('roomB').notifier)
        .add(_msg('2', 'in B'));
    expect(container.read(messageStoreProvider('roomA')).map((m) => m.body), [
      'in A',
    ]);
    expect(container.read(messageStoreProvider('roomB')).map((m) => m.body), [
      'in B',
    ]);
  });

  test('add is idempotent on duplicate id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(messageStoreProvider('roomA').notifier).add(_msg('1', 'hi'));
    container.read(messageStoreProvider('roomA').notifier).add(_msg('1', 'hi'));
    expect(container.read(messageStoreProvider('roomA')).length, 1);
  });
}
