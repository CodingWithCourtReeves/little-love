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

  test('reconcile keeps the clientMsgId for a stable list key', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('roomA').notifier);
    store.add(
      Msg(
        id: 'cli-echo',
        from: 'court',
        to: 'kaitlyn',
        body: 'hi',
        ts: DateTime.utc(2026, 6, 9, 17),
        clientMsgId: 'cli-echo',
        sendStatus: SendStatus.sending,
      ),
    );
    store.reconcile('cli-echo', _msg('ULID-real', 'hi'));
    final out = container.read(messageStoreProvider('roomA')).single;
    // id swaps to the authoritative server id, but the clientMsgId survives so
    // the bubble's ValueKey ('clientMsgId ?? id') doesn't change → no remount.
    expect(out.id, 'ULID-real');
    expect(out.clientMsgId, 'cli-echo');
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

  test('applyReaction sets, replaces, and toggles off a reaction', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('m1', 'one'));

    store.applyReaction('m1', 'kaitlyn', '❤️');
    expect(container.read(messageStoreProvider('r1')).single.reactions, {
      'kaitlyn': '❤️',
    });

    // Same user reacting with a different emoji replaces (max one per person).
    store.applyReaction('m1', 'kaitlyn', '😂');
    expect(container.read(messageStoreProvider('r1')).single.reactions, {
      'kaitlyn': '😂',
    });

    // Empty emoji removes that user's reaction.
    store.applyReaction('m1', 'kaitlyn', '');
    expect(
      container.read(messageStoreProvider('r1')).single.reactions,
      isEmpty,
    );
  });

  test('applyReaction keeps reactions from different users distinct', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('m1', 'one'));
    store.applyReaction('m1', 'court', '❤️');
    store.applyReaction('m1', 'kaitlyn', '❤️');
    expect(container.read(messageStoreProvider('r1')).single.reactions, {
      'court': '❤️',
      'kaitlyn': '❤️',
    });
  });

  test('applyReaction is a no-op when the target is absent', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('m1', 'one'));
    store.applyReaction('missing', 'court', '❤️');
    expect(
      container.read(messageStoreProvider('r1')).single.reactions,
      isEmpty,
    );
  });

  test('applyDelete removes the target message from the buffer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('m1', 'one'));
    store.add(_msg('m2', 'two'));

    store.applyDelete('m1', requestedBy: 'court');

    expect(
      container.read(messageStoreProvider('r1')).map((m) => m.id).toList(),
      ['m2'],
    );
  });

  test('applyDelete from a non-author is ignored (no spoofed unsend)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    // court authored m1 (see _msg). kaitlyn must not be able to unsend it.
    store.add(_msg('m1', 'mine'));

    store.applyDelete('m1', requestedBy: 'kaitlyn');

    expect(
      container.read(messageStoreProvider('r1')).map((m) => m.id).toList(),
      ['m1'],
      reason: 'a delete from someone who did not author the target is dropped',
    );
  });

  test('a spoofed delete that races ahead does not suppress the target', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);

    // Delete arrives before its target and names the wrong author. The
    // tombstone is recorded, but when the (court-authored) target lands it is
    // validated against the recorded deleter and survives.
    store.applyDelete('m1', requestedBy: 'kaitlyn');
    store.add(_msg('m1', 'one'));
    expect(
      container.read(messageStoreProvider('r1')).map((m) => m.id).toList(),
      ['m1'],
    );
  });

  test('a tombstoned id can never be re-added (delete wins over replay)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);

    // Delete arrives before its target (live reorder, or target replays after
    // the delete on reconnect): record the tombstone with nothing to remove...
    store.applyDelete('m1', requestedBy: 'court');
    expect(container.read(messageStoreProvider('r1')), isEmpty);

    // ...then a later add of that id (by the same author) is dropped on the spot.
    store.add(_msg('m1', 'one'));
    expect(container.read(messageStoreProvider('r1')), isEmpty);
  });

  test('setAll filters out tombstoned ids', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.applyDelete('m2', requestedBy: 'court');
    store.setAll([_msg('m1', 'one'), _msg('m2', 'two'), _msg('m3', 'three')]);
    expect(
      container.read(messageStoreProvider('r1')).map((m) => m.id).toList(),
      ['m1', 'm3'],
    );
  });

  test(
    'reconcile drops the optimistic echo when the server id is tombstoned',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('r1').notifier);
      store.add(_msg('uuid-echo', 'gone soon'));
      store.applyDelete('ULID-real', requestedBy: 'court');
      store.reconcile('uuid-echo', _msg('ULID-real', 'gone soon'));
      expect(container.read(messageStoreProvider('r1')), isEmpty);
    },
  );

  test('a cancelled send is not resurrected by a late echo', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(
      Msg(
        id: 'cli-1',
        from: 'court',
        to: 'r1',
        body: 'oops',
        ts: DateTime.utc(2026, 6, 13),
        clientMsgId: 'cli-1',
        sendStatus: SendStatus.sending,
      ),
    );

    // User cancels while in flight; the send had already reached the server, so
    // a self-copy echo arrives afterward with no optimistic row to swap.
    store.remove('cli-1');
    store.reconcile('cli-1', _msg('ULID-real', 'oops'));

    expect(
      container.read(messageStoreProvider('r1')),
      isEmpty,
      reason: 'the late echo must not re-add a cancelled send',
    );
  });

  test('remove drops a row without tombstoning (unlike applyDelete)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('cli-1', 'stuck'));

    store.remove('cli-1');
    expect(container.read(messageStoreProvider('r1')), isEmpty);

    // Not tombstoned: the same id may legitimately be added again later.
    store.add(_msg('cli-1', 'reused'));
    expect(container.read(messageStoreProvider('r1')).single.body, 'reused');
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
