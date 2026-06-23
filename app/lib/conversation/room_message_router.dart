import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/current_identity.dart';
import '../inbox/active_room_provider.dart';
import '../inbox/inbox_state.dart';
import '../inbox/select_room.dart';
import '../inbox/room.dart';
import '../outbox/outbox_store.dart';
import '../pairing/encryption.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'message_content.dart';
import 'message_store.dart';
import 'presence_state.dart';
import 'room_key_cache.dart';
import 'typing_state.dart';

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
  // Per-room debounce for the "viewing this room → tell the server I've read up
  // to the latest message" frame. Coalesces a replay burst into a single
  // MarkRead and rechecks selection when it fires (so it survives the
  // cold-launch race where messages replay just before the room auto-selects).
  final Map<String, Timer> _markReadDebounce = {};

  void _scheduleMarkRead(String roomId) {
    _markReadDebounce[roomId]?.cancel();
    _markReadDebounce[roomId] = Timer(const Duration(milliseconds: 400), () {
      _markReadDebounce.remove(roomId);
      if (ref.read(activeRoomProvider) == roomId) {
        sendMarkRead(ref, roomId);
      }
    });
  }

  Future<void> _onFrame(RoomServerFrame f) async {
    switch (f) {
      case RoomsFrame(:final rooms):
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
        // The authoritative room list has landed — the inbox is now synced, so
        // an empty list reads as "unpaired" rather than "still loading".
        ref.read(inboxSyncedProvider.notifier).state = true;
        for (final r in mapped) {
          _subscribe(r.roomId);
        }

      case RoomCreatedFrame(:final roomId, :final name, :final members):
        _upsertRoom(roomId, name, members);
        _subscribe(roomId);

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

      case ReadFrame(:final roomId, :final messageIds):
        ref.read(messageStoreProvider(roomId).notifier).markRead(messageIds);

      case TypingFrame(:final roomId, :final typing):
        // 1:1 rooms: the only other member is the partner, so a relayed Typing
        // frame is always "the partner is typing" in this room.
        ref.read(typingProvider(roomId).notifier).setTyping(typing);

      case PresenceFrame(:final user, :final online):
        // Server-authoritative partner online/offline, keyed by username.
        ref.read(presenceProvider(user).notifier).setOnline(online);

      case InviteCreatedFrame():
      case RoomErrorFrame():
      case UploadGrantedFrame():
      case DownloadGrantedFrame():
        // Owned by LivePairingTransport / attachment upload+download flows.
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
    // A decrypt failure returns the sentinel; render it as text verbatim
    // rather than trying to parse it as an envelope.
    final content = plaintext == cannotDecryptSentinel
        ? const TextContent(cannotDecryptSentinel)
        : MessageContent.decode(plaintext);
    final store = ref.read(messageStoreProvider(f.roomId).notifier);
    // A reaction isn't a timeline bubble: apply it onto its target and stop.
    // The sender's own self-copy still rides the outbox, so drop that row on
    // echo just like a normal send (otherwise the drain resends it).
    if (content is ReactionContent) {
      store.applyReaction(content.targetId, f.from, content.emoji);
      if (f.clientMsgId != null) {
        final outbox = await ref.read(outboxStoreProvider.future);
        await outbox.remove(f.clientMsgId!);
      }
      return;
    }
    // An unsend isn't a timeline bubble either: tombstone its target and stop.
    // Only the message's author may unsend it — `applyDelete` drops a delete
    // whose `requestedBy` doesn't match the target's author (a spoofed delete,
    // possible because both partners share the room key). Same outbox cleanup
    // on the sender's self-copy echo as a reaction.
    if (content is DeleteContent) {
      store.applyDelete(content.targetId, requestedBy: f.from);
      if (f.clientMsgId != null) {
        final outbox = await ref.read(outboxStoreProvider.future);
        await outbox.remove(f.clientMsgId!);
      }
      return;
    }
    // `read` is only set on the sender's own self-copy that the partner has
    // seen; replay it as the double-heart state. Otherwise default sent.
    final sendStatus = f.read ? SendStatus.read : SendStatus.sent;
    final msg = switch (content) {
      TextContent(:final text, :final preview) => Msg(
        id: f.id,
        from: f.from,
        to: f.roomId,
        body: text,
        ts: f.ts,
        replayed: f.replayed,
        sendStatus: sendStatus,
        linkPreview: preview,
      ),
      FileContent(:final descriptor, :final caption) => Msg(
        id: f.id,
        from: f.from,
        to: f.roomId,
        body: caption ?? '',
        ts: f.ts,
        replayed: f.replayed,
        attachment: descriptor,
        sendStatus: sendStatus,
      ),
      // Voice memos carry the audio descriptor (incl. waveform) as the
      // attachment, same as a file; the bubble renders it as a player.
      AudioContent(:final descriptor, :final caption) => Msg(
        id: f.id,
        from: f.from,
        to: f.roomId,
        body: caption ?? '',
        ts: f.ts,
        replayed: f.replayed,
        attachment: descriptor,
        sendStatus: sendStatus,
      ),
      // Handled by the early returns above; here only for exhaustiveness.
      ReactionContent() => throw StateError('reaction handled above'),
      DeleteContent() => throw StateError('delete handled above'),
    };
    // Live self-copy of our own message: swap the optimistic echo (keyed by
    // clientMsgId) for this authoritative row instead of appending a duplicate.
    // The echo also confirms the server durably stored the send, so drop the
    // persisted outbox row — the drain must not resend it on the next cycle.
    if (f.clientMsgId != null) {
      final outbox = await ref.read(outboxStoreProvider.future);
      await outbox.remove(f.clientMsgId!);
      store.reconcile(f.clientMsgId!, msg);
    } else {
      // Sending ends typing: clear the partner's typing flag in the same
      // update that adds their message, so the typing bubble collapses and the
      // new bubble appears in one layout pass instead of two (the second being
      // a separately-timed Typing:false frame) — which read as a flash.
      ref.read(typingProvider(f.roomId).notifier).setTyping(false);
      store.add(msg);
      // A live partner message landing in the open room should flip the
      // sender's bubble to a double heart now, not on the next reopen.
      // `clientMsgId == null && !replayed` is precisely a live partner message
      // (my own live self-copy always carries a clientMsgId, handled above;
      // replays are covered by the open trigger and must not spam a MarkRead
      // per row). The watermark in sendMarkRead already covers this message
      // since it's in the store before this runs.
      if (!f.replayed && ref.read(activeRoomProvider) == f.roomId) {
        // The chat is on screen, so this message is read: tell the server AND
        // advance our local read marker, so leaving the room doesn't leave a
        // phantom unread dot for a message we just watched arrive.
        markRoomRead(ref, f.roomId);
      }
      // Replayed messages (reconnect / cold launch / a push received while
      // backgrounded) must ALSO reach the server, or read_at stays NULL and the
      // app-icon badge — driven server-side off unread_count — climbs and never
      // clears. The old code skipped replays, assuming an explicit room-open tap
      // would cover them; in this always-auto-selected couples app there is no
      // such tap. Debounced so a full replay burst sends one MarkRead.
      if (f.replayed) {
        _scheduleMarkRead(f.roomId);
      }
    }
  }

  Future<void> dispose() async {
    for (final t in _markReadDebounce.values) {
      t.cancel();
    }
    _markReadDebounce.clear();
    await _sub.cancel();
  }
}

final roomMessageRouterProvider = Provider<RoomMessageRouter>((ref) {
  final conn = ref.watch(liveConnectionProvider).requireValue;
  final router = RoomMessageRouter(ref: ref, conn: conn);
  ref.onDispose(router.dispose);
  return router;
});
