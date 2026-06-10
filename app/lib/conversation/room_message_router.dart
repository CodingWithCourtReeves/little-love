import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/current_identity.dart';
import '../inbox/inbox_state.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'message_store.dart';
import 'room_key_cache.dart';

/// Listens to the live WSS connection and dispatches room-phase frames into
/// the inbox + per-room message stores. Auto-subscribes to each room as it
/// appears so the server starts replay + live delivery.
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
      case RoomsFrame(:final rooms):
        final mapped = rooms
            .map(
              (p) => Room(
                roomId: p.roomId,
                peerUsername: p.peerUsername,
                peerEd25519PubBase64: p.peerEd25519PubBase64,
                peerX25519PubBase64: p.peerX25519PubBase64,
                createdAt: p.createdAt ?? DateTime.now().toUtc(),
              ),
            )
            .toList(growable: false);
        ref.read(inboxStateProvider.notifier).setRooms(mapped);
        for (final r in mapped) {
          _subscribe(r.roomId);
        }
      case RoomCreatedFrame(:final peer):
        final current = ref.read(inboxStateProvider).rooms.toList();
        if (current.any((r) => r.roomId == peer.roomId)) {
          _subscribe(peer.roomId);
          return;
        }
        current.add(
          Room(
            roomId: peer.roomId,
            peerUsername: peer.peerUsername,
            peerEd25519PubBase64: peer.peerEd25519PubBase64,
            peerX25519PubBase64: peer.peerX25519PubBase64,
            createdAt: peer.createdAt ?? DateTime.now().toUtc(),
          ),
        );
        ref.read(inboxStateProvider.notifier).setRooms(current);
        _subscribe(peer.roomId);
      case InviteConsumedFrame(:final peer):
        // Consumer side already calls setRooms in EnterCodeScreen; we just
        // make sure we subscribe so subsequent messages flow.
        _subscribe(peer.roomId);
      case MessageFrame():
        await _ingestMessage(f);
      case InviteCreatedFrame():
      case RoomErrorFrame():
        // InviteCreated + RoomError belong to LivePairingTransport.
        break;
    }
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
    final me = await ref.read(currentIdentityProvider.future);
    final key = await ref.read(roomKeyCacheProvider).getOrDerive(room, me);
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
