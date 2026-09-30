import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/outbox/outbox_drain.dart';
import 'package:littlelove/outbox/outbox_retry.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/wire/message.dart';

import 'memory_outbox_store.dart';

/// An outbox whose drain read fails (e.g. the sqflite store errors), so
/// `drain.kick()` throws.
class _PendingFails extends MemoryOutboxStore {
  @override
  Future<List<OutboxRow>> pending() async => throw StateError('db unavailable');
}

Msg _failed() => Msg(
  id: 'cli-1',
  from: 'me',
  to: 'r1',
  body: 'eh',
  ts: DateTime.utc(2026, 6, 13),
  clientMsgId: 'cli-1',
  sendStatus: SendStatus.failed,
);

void main() {
  Future<(ProviderContainer, MessageStore)> setUpRow(OutboxStore store) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await store.enqueue(
      clientMsgId: 'cli-1',
      roomId: 'r1',
      bodies: const {'k': 'ct'},
    );
    final msgs = c.read(messageStoreProvider('r1').notifier)..add(_failed());
    return (c, msgs);
  }

  test('retry flips the row to sending and re-sends it', () async {
    final store = MemoryOutboxStore();
    final (c, _) = await setUpRow(store);
    final sent = <String>[];
    final drain = OutboxDrain(store: store, send: (_, _, id) => sent.add(id));

    await retryOutboxSend(
      store: store,
      drain: drain,
      messages: (roomId) => c.read(messageStoreProvider(roomId).notifier),
      clientMsgId: 'cli-1',
    );

    expect(sent, ['cli-1']);
    expect(
      c.read(messageStoreProvider('r1')).single.sendStatus,
      SendStatus.sending,
    );
  });

  test('a retry whose drain throws lands back on failed (never stuck on the '
      'non-retryable clock)', () async {
    final store = _PendingFails();
    final (c, _) = await setUpRow(store);
    final drain = OutboxDrain(store: store, send: (_, _, _) {});

    await retryOutboxSend(
      store: store,
      drain: drain,
      messages: (roomId) => c.read(messageStoreProvider(roomId).notifier),
      clientMsgId: 'cli-1',
    );

    expect(
      c.read(messageStoreProvider('r1')).single.sendStatus,
      SendStatus.failed,
    );
  });

  test('retrying an id with no outbox row is a no-op', () async {
    final store = MemoryOutboxStore();
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('r1').notifier).add(_failed());
    final drain = OutboxDrain(store: store, send: (_, _, _) {});

    await retryOutboxSend(
      store: store,
      drain: drain,
      messages: (roomId) => c.read(messageStoreProvider(roomId).notifier),
      clientMsgId: 'cli-1',
    );

    expect(
      c.read(messageStoreProvider('r1')).single.sendStatus,
      SendStatus.failed,
    );
  });
}
