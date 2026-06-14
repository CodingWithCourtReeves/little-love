import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../conversation/room_key_cache.dart';
import '../identity/current_identity.dart';
import '../identity/keypair.dart';
import '../identity/providers.dart';
import '../inbox/inbox_state.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../wire/message.dart';
import 'outbox_store.dart';

typedef OutboxDecrypt = Future<String> Function(Room room, String cipher);

/// Re-insert optimistic bubbles for every persisted outbox row. Runs once
/// after the room list is known, independent of WS state — without this,
/// killing the app mid-send would erase the bubble until the eventual echo
/// reappeared.
///
/// Dependencies are passed in plainly rather than via a [Ref] so the same
/// function can be called from a [ConsumerWidget]'s [WidgetRef] (production)
/// or a [ProviderContainer] (tests) without a coercion dance.
Future<void> rehydrateOutbox({
  required OutboxStore store,
  required String me,
  required DerivedIdentity identity,
  required RoomKeyCache keyCache,
  required List<Room> rooms,
  required MessageStore Function(String roomId) getMessageStore,
  OutboxDecrypt? decrypt,
}) async {
  final rows = await store.pending();
  if (rows.isEmpty) return;

  final byId = {for (final r in rooms) r.roomId: r};

  for (final row in rows) {
    final room = byId[row.roomId];
    if (room == null) continue; // stale row, skip
    String text;
    try {
      if (decrypt != null) {
        text = await decrypt(room, row.bodyCipher);
      } else {
        final key = await keyCache.getOrDerive(room, identity);
        text = await decryptIncoming(key, row.bodyCipher);
      }
    } catch (_) {
      await store.markAttempt(row.clientMsgId, error: 'decrypt-failed');
      getMessageStore(row.roomId).add(Msg(
            id: row.clientMsgId,
            from: me,
            to: row.roomId,
            body: '(message could not be decrypted)',
            ts: row.createdAt,
            clientMsgId: row.clientMsgId,
            sendStatus: SendStatus.failed,
          ));
      continue;
    }
    getMessageStore(row.roomId).add(Msg(
          id: row.clientMsgId,
          from: me,
          to: row.roomId,
          body: text,
          ts: row.createdAt,
          clientMsgId: row.clientMsgId,
          sendStatus: SendStatus.sending,
        ));
  }
}

/// Mounts under the inbox shell. The first time the room list is non-empty,
/// kick a one-shot rehydration. The gate is cheap and idempotent.
class OutboxRehydrateGate extends ConsumerStatefulWidget {
  const OutboxRehydrateGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<OutboxRehydrateGate> createState() =>
      _OutboxRehydrateGateState();
}

class _OutboxRehydrateGateState extends ConsumerState<OutboxRehydrateGate> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    if (!_done) {
      final hasRooms = ref.watch(inboxStateProvider).rooms.isNotEmpty;
      if (hasRooms) {
        _done = true;
        Future<void>(() async {
          final store = await ref.read(outboxStoreProvider.future);
          final account = await ref.read(accountProvider.future);
          if (account == null) return;
          final identity = await ref.read(currentIdentityProvider.future);
          await rehydrateOutbox(
            store: store,
            me: account.username,
            identity: identity,
            keyCache: ref.read(roomKeyCacheProvider),
            rooms: ref.read(inboxStateProvider).rooms,
            getMessageStore: (roomId) =>
                ref.read(messageStoreProvider(roomId).notifier),
          );
        });
      }
    }
    return widget.child;
  }
}
