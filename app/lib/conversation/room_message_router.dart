import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/current_identity.dart';
import '../inbox/inbox_state.dart';
import '../inbox/owned_bots_provider.dart';
import '../inbox/select_room.dart';
import '../inbox/pending_invites_provider.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'message_store.dart';
import 'room_key_cache.dart';

/// Listens to the live WSS connection and dispatches v0.3 room-phase frames
/// into the inbox + per-room message stores. Auto-subscribes to each room as
/// it appears so the server starts replay + live delivery.
class RoomMessageRouter {
  RoomMessageRouter({required this.ref, required this.conn}) {
    _sub = conn.incoming.listen(_onFrame);
  }

  final Ref ref;
  final LiveConnection conn;
  late final StreamSubscription<RoomServerFrame> _sub;
  final Set<String> _subscribed = {};

  Future<void> _onFrame(RoomServerFrame f) async {
    switch (f) {
      case RoomsFrame(:final rooms, :final ownedBots):
        final mapped = rooms
            .map(
              (r) => Room(
                roomId: r.roomId,
                name: r.name,
                members: r.members,
                createdAt: r.createdAt,
              ),
            )
            .toList(growable: false);
        ref.read(inboxStateProvider.notifier).setRooms(mapped);
        ref.read(ownedBotsProvider.notifier).set(ownedBots);
        for (final r in mapped) {
          _subscribe(r.roomId);
        }

      case RoomCreatedFrame(
        :final roomId,
        :final name,
        :final members,
        :final pendingInvite,
      ):
        _upsertRoom(roomId, name, members);
        _subscribe(roomId);
        if (pendingInvite != null) {
          ref.read(pendingInvitesProvider.notifier).set(roomId, pendingInvite);
        }
        // The creator just made this room — drop them into it and mark read.
        // For a pending-invite room this routes to the invite-code screen via
        // inbox_shell; otherwise straight into the conversation.
        selectAndMarkRead(ref, roomId);

      case InviteConsumedFrame(:final roomId, :final name, :final members):
        _upsertRoom(roomId, name, members);
        _subscribe(roomId);

      case RoomRenamedFrame(:final roomId, :final name):
        ref.read(inboxStateProvider.notifier).renameRoom(roomId, name);

      case MemberLeftFrame(:final roomId, :final username):
        ref.read(inboxStateProvider.notifier).removeMember(roomId, username);
        ref.read(roomKeyCacheProvider).invalidate(roomId);

      case MessageFrame():
        await _ingestMessage(f);

      case InviteCreatedFrame():
      case RoomErrorFrame():
        // Owned by LivePairingTransport / CreateChat screens.
        break;
    }
  }

  void _upsertRoom(String roomId, String name, List<Member> members) {
    final current = ref.read(inboxStateProvider).rooms.toList();
    current.removeWhere((r) => r.roomId == roomId);
    current.add(
      Room(
        roomId: roomId,
        name: name,
        members: members,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    ref.read(inboxStateProvider.notifier).setRooms(current);
  }

  void _subscribe(String roomId) {
    if (!_subscribed.add(roomId)) return;
    conn.send(SubscribeFrame(roomId: roomId, sinceMessageId: null).toJson());
  }

  Future<void> _ingestMessage(MessageFrame f) async {
    final inbox = ref.read(inboxStateProvider);
    Room? room;
    for (final r in inbox.rooms) {
      if (r.roomId == f.roomId) {
        room = r;
        break;
      }
    }
    if (room == null) return;
    final sender = room.memberByUsername(f.from);
    if (sender == null) return;
    final me = await ref.read(currentIdentityProvider.future);
    final key = await ref
        .read(roomKeyCacheProvider)
        .getOrDeriveFor(
          roomId: room.roomId,
          peerX25519PubBase64: sender.x25519PubBase64,
          me: me,
        );
    final plaintext = await decryptIncoming(key, f.body);
    ref
        .read(messageStoreProvider(f.roomId).notifier)
        .add(
          Msg(
            id: f.id,
            from: f.from,
            to: f.roomId,
            body: plaintext,
            ts: f.ts,
            replayed: f.replayed,
          ),
        );
  }

  Future<void> dispose() async {
    await _sub.cancel();
  }
}

final roomMessageRouterProvider = Provider<RoomMessageRouter>((ref) {
  final conn = ref.watch(liveConnectionProvider).requireValue;
  final router = RoomMessageRouter(ref: ref, conn: conn);
  ref.onDispose(router.dispose);
  return router;
});
