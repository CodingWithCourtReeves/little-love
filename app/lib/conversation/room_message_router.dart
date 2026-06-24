import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_download.dart';
import '../calling/call_log.dart';
import '../identity/current_identity.dart';
import '../identity/providers.dart';
import '../inbox/active_room_provider.dart';
import '../inbox/inbox_state.dart';
import '../inbox/select_room.dart';
import '../inbox/room.dart';
import '../outbox/outbox_store.dart';
import '../pairing/encryption.dart';
import '../profile/profile_publish_cache.dart';
import '../profile/profile_service.dart';
import '../profile/profile_store.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'incoming_banner_provider.dart';
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
        // Re-assert my own profile to the partner now that the room list (and
        // thus the couple room) is known. Covers a pre-pairing edit and every
        // reconnect; idempotent + latest-wins on the receiver. Reuses the cached
        // avatar descriptor, so no photo re-upload.
        unawaited(_republishMyProfile());

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

      case ProfileFrame():
        await _ingestProfile(f);

      case InviteCreatedFrame():
      case RoomErrorFrame():
      case UploadGrantedFrame():
      case DownloadGrantedFrame():
      case CallTurnGrantFrame():
      case CallInviteFrame():
      case CallAnswerFrame():
      case CallIceFrame():
      case CallHangupFrame():
        // Owned by LivePairingTransport / attachment upload+download flows /
        // the call controller (which subscribes to call frames directly).
        break;
    }
  }

  /// Decrypt a relayed partner profile and apply it to the ProfileStore. The
  /// pairwise key is salted by the canonical couple-room id (see [coupleRoomFor]),
  /// so we resolve the same room the publisher used. A Profile can arrive before
  /// the room list reconciles; if so we drop it — the connect-time replay (and
  /// any later live publish) re-delivers it once the room is present.
  Future<void> _ingestProfile(ProfileFrame f) async {
    final account = await ref.read(accountProvider.future);
    if (account == null) return;
    final room = coupleRoomFor(
      ref.read(inboxStateProvider).rooms,
      account.username,
    );
    if (room == null) return;
    final me = await ref.read(currentIdentityProvider.future);
    final store = ref.read(profileStoreProvider);
    await handleIncomingProfile(
      f,
      coupleRoom: room,
      me: me,
      selfUsername: account.username,
      cache: ref.read(roomKeyCacheProvider),
      store: store,
      receivedAt: DateTime.now().toUtc(),
    );
    // Fetch + decrypt the partner's avatar blob (named by the descriptor) so the
    // room list / chat header can render it. Cached by blob key, so an unchanged
    // avatar resolves instantly on a reconnect.
    final descriptor = store.forUsername(f.user)?.avatar;
    if (descriptor != null) {
      try {
        final file = await fetchAndDecrypt(conn: conn, descriptor: descriptor);
        store.setAvatarFile(f.user, file);
      } catch (_) {
        // Best-effort: keep the initials fallback if the blob can't be fetched.
      }
    }
  }

  /// Re-publish my own profile (display name + cached avatar) to my partner on
  /// connect. No-ops before pairing or when nothing has been set.
  Future<void> _republishMyProfile() async {
    final account = await ref.read(accountProvider.future);
    if (account == null) return;
    if (account.displayName == null && account.avatarPath == null) return;
    final conn = ref.read(liveConnectionProvider).valueOrNull;
    final rooms = ref.read(inboxStateProvider).rooms;
    final room = coupleRoomFor(rooms, account.username);
    if (conn == null || room == null) return;
    final cache = ref.read(profilePublishCacheProvider);
    // Upload the avatar on connect if it hasn't landed yet (e.g. the upload
    // failed earlier on a flaky connection). This is the stable post-connect
    // window, so a previously-stuck photo finally syncs here. Best-effort: fall
    // back to whatever's cached if this attempt also fails.
    AttachmentDescriptor? avatar;
    try {
      avatar = await ensureAvatarUploaded(
        conn: conn,
        room: room,
        avatarPath: account.avatarPath,
        cache: cache,
      );
    } catch (_) {
      avatar = await cache.avatar();
    }
    final me = await ref.read(currentIdentityProvider.future);
    await assembleAndPublishProfile(
      conn: conn,
      rooms: rooms,
      selfUsername: account.username,
      displayName: account.displayName,
      me: me,
      keyCache: ref.read(roomKeyCacheProvider),
      avatar: avatar,
      avatarKey: avatar?.blobKey,
    );
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
      // A call-log entry renders as a (currently text-style) timeline row.
      CallContent(:final outcome, :final durationS, :final video) => Msg(
        id: f.id,
        from: f.from,
        to: f.roomId,
        body: callLogSummary(outcome, durationS, video: video),
        ts: f.ts,
        replayed: f.replayed,
        sendStatus: sendStatus,
        callOutcome: outcome,
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
      // `clientMsgId == null && !replayed` is precisely a live partner message
      // (my own live self-copy always carries a clientMsgId, handled above;
      // replays are covered by the open trigger and must not spam a MarkRead
      // per row, nor pop a banner).
      if (!f.replayed) {
        if (ref.read(activeRoomProvider) == f.roomId) {
          // The chat is on screen: flip the sender's bubble to a double heart
          // now (not on the next reopen). Tell the server AND advance our local
          // read marker, so leaving the room doesn't leave a phantom unread dot
          // for a message we just watched arrive. The watermark in sendMarkRead
          // already covers this message since it's in the store before this runs.
          markRoomRead(ref, f.roomId);
        } else {
          // A live message in a room that isn't on screen: pop an in-app banner
          // so partner activity in another thread isn't invisible while you're
          // reading a different one.
          _showIncomingBanner(room, f, content);
        }
      } else {
        // Replayed messages (reconnect / cold launch / a push received while
        // backgrounded) must ALSO reach the server, or read_at stays NULL and
        // the app-icon badge — driven server-side off unread_count — climbs and
        // never clears. In this always-auto-selected couples app there is no
        // explicit room-open tap to cover them. Debounced so a full replay burst
        // sends one MarkRead. No banner: a reconnect would otherwise storm them.
        _scheduleMarkRead(f.roomId);
      }
    }
  }

  /// Publish the "message arrived in another room" banner event. Called only on
  /// the live, non-active, partner-message path (reactions/deletes already
  /// returned; self-copies carry a clientMsgId and never reach here).
  void _showIncomingBanner(Room room, MessageFrame f, MessageContent content) {
    final preview = switch (content) {
      TextContent(:final text) => text,
      FileContent(:final caption) =>
        (caption != null && caption.isNotEmpty) ? caption : '📷 Photo',
      AudioContent(:final caption) =>
        (caption != null && caption.isNotEmpty) ? caption : '🎤 Voice message',
      _ => '',
    };
    // Named room → its topic; otherwise the partner's display name (the DM).
    String name = room.name;
    if (name.isEmpty) {
      final dn = ref
          .read(profileStoreProvider)
          .forUsername(f.from)
          ?.displayName;
      name = (dn != null && dn.trim().isNotEmpty)
          ? dn.trim()
          : (f.from.isEmpty
                ? 'Your partner'
                : f.from[0].toUpperCase() + f.from.substring(1));
    }
    ref
        .read(incomingBannerProvider.notifier)
        .show(
          IncomingBanner(
            roomId: f.roomId,
            roomName: name,
            preview: preview,
            msgId: f.id,
          ),
        );
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
