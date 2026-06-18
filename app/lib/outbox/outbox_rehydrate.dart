import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_content.dart';
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
    // The bubble shows our own plaintext, so decrypt the self-copy — the
    // ciphertext addressed to our own x25519 key (see buildSendFrame).
    final selfPub = room.memberByUsername(me)?.x25519PubBase64;
    final selfCipher = selfPub == null ? null : row.bodies[selfPub];

    String? text;
    if (selfCipher != null) {
      try {
        if (decrypt != null) {
          text = await decrypt(room, selfCipher);
        } else {
          final key = await keyCache.getOrDeriveFor(
            roomId: room.roomId,
            peerX25519PubBase64: selfPub!,
            me: identity,
          );
          text = await decryptIncoming(key, selfCipher);
        }
      } catch (_) {
        text = null;
      }
    }

    if (text == null || text == cannotDecryptSentinel) {
      await store.markAttempt(row.clientMsgId, error: 'decrypt-failed');
      getMessageStore(row.roomId).add(
        Msg(
          id: row.clientMsgId,
          from: me,
          to: row.roomId,
          body: '(message could not be decrypted)',
          ts: row.createdAt,
          clientMsgId: row.clientMsgId,
          sendStatus: SendStatus.failed,
        ),
      );
      continue;
    }
    // The decrypted plaintext is an encoded envelope, not display text. Decode
    // it the same way the inbound router does so a file rehydrates as a media
    // bubble instead of dumping its raw descriptor JSON into the timeline.
    final content = MessageContent.decode(text);
    // A pending reaction is not a timeline bubble; it applies onto its target
    // when it drains. Leave the row to drain and render nothing here.
    if (content is ReactionContent) continue;
    final (body, attachment) = switch (content) {
      TextContent(:final text) => (text, null),
      FileContent(:final descriptor, :final caption) => (
        caption ?? '',
        descriptor,
      ),
      ReactionContent() => ('', null), // handled by the continue above
    };
    getMessageStore(row.roomId).add(
      Msg(
        id: row.clientMsgId,
        from: me,
        to: row.roomId,
        body: body,
        ts: row.createdAt,
        clientMsgId: row.clientMsgId,
        sendStatus: SendStatus.sending,
        attachment: attachment,
      ),
    );
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
