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

  test('reconcile swaps the optimistic echo id in place', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.add(_msg('uuid-echo', 'first'));
    store.add(_msg('2', 'second'));

    store.reconcile('uuid-echo', _msg('ULID-real', 'first'));

    final out = container.read(messageStoreProvider('roomA'));
    // Position preserved, id swapped to the authoritative server id.
    expect(out.map((m) => m.id).toList(), ['ULID-real', '2']);
    expect(out.length, 2);
  });

  test('reconcile is idempotent once the server id is present', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.add(_msg('uuid-echo', 'first'));
    store.reconcile('uuid-echo', _msg('ULID-real', 'first'));
    // A duplicate echo (e.g. a reconnect replay) must not double-up.
    store.reconcile('uuid-echo', _msg('ULID-real', 'first'));
    expect(container.read(messageStoreProvider('roomA')).length, 1);
  });

  test('reconcile falls back to append when no echo exists', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.reconcile('missing-echo', _msg('ULID-real', 'orphan'));
    final out = container.read(messageStoreProvider('roomA'));
    expect(out.single.id, 'ULID-real');
  });

  test('markRead flips matching ids to SendStatus.read, leaves others', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('m1', 'one'));
    store.add(_msg('m2', 'two'));
    store.add(_msg('m3', 'three'));

    store.markRead(['m1', 'm3']);

    final out = container.read(messageStoreProvider('r1'));
    expect(out.firstWhere((m) => m.id == 'm1').sendStatus, SendStatus.read);
    expect(out.firstWhere((m) => m.id == 'm3').sendStatus, SendStatus.read);
    expect(out.firstWhere((m) => m.id == 'm2').sendStatus, SendStatus.sent);
  });

  test('updateStatus changes sendStatus on the matching id', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(
      Msg(
        id: 'cli-1',
        from: 'me',
        to: 'r1',
        body: 'hi',
        ts: DateTime.utc(2026, 6, 13),
        clientMsgId: 'cli-1',
        sendStatus: SendStatus.sending,
      ),
    );
    store.updateStatus('cli-1', SendStatus.failed);
    expect(
      container.read(messageStoreProvider('r1')).single.sendStatus,
      SendStatus.failed,
    );
  });
}
