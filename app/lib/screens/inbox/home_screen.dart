import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../attachment/attachment_descriptor.dart';
import '../../attachment/attachment_download.dart';
import '../../attachment/attachment_upload.dart';
import '../../attachment/attachment_viewer.dart';
import '../../attachment/file_crypto.dart';
import '../../attachment/staged_attachment.dart';
import '../../attachment/thumbnail.dart';
import '../../conversation/conversation_page.dart';
import '../../conversation/link_preview.dart';
import '../../conversation/message_content.dart';
import '../../conversation/message_store.dart';
import '../../conversation/room_key_cache.dart';
import '../../conversation/room_message_router.dart';
import '../../conversation/send_fanout.dart';
import '../../identity/account_local.dart';
import '../../identity/current_identity.dart';
import '../../identity/sign_out.dart';
import '../../inbox/active_room_provider.dart';
import '../../inbox/conversation_list_item.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/read_state_provider.dart';
import '../../inbox/room.dart';
import '../../outbox/outbox_drain.dart';
import '../../outbox/outbox_store.dart';
import '../../push/push_bootstrap.dart';
import '../../theme/app_palette.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';
import '../../wire/message.dart';
import '../create_chat/create_channel_sheet.dart';
import '../pair/pairing_screen.dart';

/// Signed-in root: the conversation list is home. Tapping a room pushes a
/// [ConversationPage]; back pops here. When there are no rooms, the body is the
/// pairing affordance. Keeps the room message router + outbox drain alive while
/// mounted (was InboxShell's job).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, required this.account});

  final LocalAccount account;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Guards single-room auto-open so it fires at most once per mount.
  bool _autoOpened = false;

  /// True while a ConversationPage route is on top of Home, so the auto-open
  /// listener never double-pushes.
  bool _chatOnStack = false;

  String get _me => widget.account.username;

  @override
  Widget build(BuildContext context) {
    // Activate router + outbox drain for this session (was InboxShell.build).
    ref.watch(liveConnectionProvider).whenData((_) {
      ref.watch(roomMessageRouterProvider);
      ref.watch(outboxDrainProvider);
    });

    final inbox = ref.watch(inboxStateProvider);
    if (inbox.rooms.isNotEmpty) {
      ref.watch(pushBootstrapProvider);
    }
    ref.watch(badgeSyncProvider(_me));

    // A notification tap (or any out-of-tree caller) requests a room by id.
    // Consume the command and push its conversation, unless it's already on
    // screen. Resetting the signal must be deferred — Riverpod forbids mutating
    // a provider inside a listener that runs during build.
    ref.listen<String?>(requestedRoomProvider, (_, roomId) {
      if (roomId == null) return;
      Room? target;
      for (final r in inbox.rooms) {
        if (r.roomId == roomId) {
          target = r;
          break;
        }
      }
      Future.microtask(
        () => ref.read(requestedRoomProvider.notifier).state = null,
      );
      if (target == null) return;
      if (ref.read(activeRoomProvider) == roomId) return; // already open
      _openRoom(target);
    });

    // Single-room auto-open: exactly one *partner* room → push straight into
    // it, so the couples-app "into the chat" feel survives without abandoning
    // the list. A lone solo room (a freshly created invite, no partner yet)
    // must NOT auto-open, or creating an invite dumps you into an empty chat.
    if (!_autoOpened &&
        !_chatOnStack &&
        inbox.rooms.length == 1 &&
        inbox.rooms.single.shape(_me) == RoomShape.partner) {
      _autoOpened = true;
      final only = inbox.rooms.single;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openRoom(only));
    }

    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        elevation: 0,
        title: Text('@$_me'),
        actions: [
          if (inbox.rooms.isNotEmpty)
            IconButton(
              key: const Key('home-new-chat'),
              icon: const Icon(Icons.add),
              tooltip: 'New channel',
              // Any room in the inbox implies a partner (roomless invites mean
              // no solo room ever exists), so [+] always opens a topical
              // channel with that partner. Pre-pairing lives in the empty
              // state's PairingScreen, never behind [+].
              onPressed: () => showCreateChannelSheet(context, ref),
            ),
          PopupMenuButton<String>(
            key: const Key('home-menu'),
            onSelected: (value) {
              if (value == 'signout') _confirmSignOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: 'signout',
                child: Text('Sign out'),
              ),
            ],
          ),
        ],
      ),
      body: _body(inbox.rooms),
    );
  }

  Widget _body(List<Room> rooms) {
    if (rooms.isNotEmpty) return _roomList(rooms);
    // Empty inbox: distinguish "still syncing" from "genuinely unpaired" so we
    // don't flash the pairing screen on launch before the room list arrives.
    final synced = ref.watch(inboxSyncedProvider);
    final connFailed = ref.watch(liveConnectionProvider).hasError;
    if (synced || connFailed) return _emptyState();
    // First sync in flight — a blank canvas (no flash).
    return const SizedBox.expand();
  }

  /// True iff [roomId] has an incoming (partner) message past its read marker.
  bool _roomUnread(String roomId, Map<String, DateTime> markers) {
    final marker = markers[roomId];
    for (final m in ref.watch(messageStoreProvider(roomId))) {
      if (m.from == _me) continue;
      if (marker == null || m.ts.isAfter(marker)) return true;
    }
    return false;
  }

  Widget _emptyState() {
    return PairingScreen(selfUsername: _me);
  }

  Widget _roomList(List<Room> rooms) {
    final markers = ref.watch(readStateProvider);
    List<Room> bucket(RoomShape shape) =>
        rooms.where((r) => r.shape(_me) == shape).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final partners = bucket(RoomShape.partner);
    final chats = bucket(RoomShape.chat);

    Widget header(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: context.palette.textMuted,
          letterSpacing: 1.2,
        ),
      ),
    );

    Widget item(Room r) => ConversationListItem(
      key: Key('home-room-${r.roomId}'),
      label: r.displayName(_me),
      selected: false,
      unread: _roomUnread(r.roomId, markers),
      onTap: () => _openRoom(r),
    );

    return ListView(
      children: [
        if (partners.isNotEmpty) header('PARTNER'),
        ...partners.map(item),
        if (chats.isNotEmpty) ...[const SizedBox(height: 16), header('CHATS')],
        ...chats.map(item),
      ],
    );
  }

  Future<void> _openRoom(Room room) async {
    _chatOnStack = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          key: ValueKey(room.roomId),
          room: room,
          selfUsername: _me,
          onSend: (text) => _sendEncrypted(ref, room, text),
          onRetry: (clientMsgId) => _retry(ref, clientMsgId),
          onPickMedia: () => _pickMedia(context),
          onSendMedia: (items, caption) =>
              _sendStaged(ref, room, context, items, caption),
          onReact: (targetId, emoji) =>
              _sendReaction(ref, room, targetId, emoji),
          onDelete: (targetId) => _sendDelete(ref, room, targetId),
          onCancelSend: (clientMsgId) => _cancelSend(ref, room, clientMsgId),
          onTyping: (typing) => _sendTyping(ref, room, typing),
          onOpenAttachment: (descriptor) =>
              _openAttachment(ref, room, context, descriptor),
          onRename: (newName) {
            final conn = ref.read(liveConnectionProvider).asData?.value;
            conn?.send(
              RenameRoomFrame(roomId: room.roomId, name: newName).toJson(),
            );
          },
        ),
      ),
    );
    _chatOnStack = false;
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes this account and its messages from this device. You '
          'can sign back in with your recovery phrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-signout'),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) await signOut(ref);
  }

  // ---- send/retry/media wiring moved verbatim from inbox_shell.dart ----

  /// Route a send through the persistent outbox so it survives a WS reconnect
  /// (or an app kill) mid-send. We persist the ciphertext envelope, render an
  /// optimistic in-flight bubble (clock marker) immediately, then kick the
  /// drain — the row flips to a heart once the server echoes it back (see
  /// [RoomMessageRouter]).
  Future<void> _sendEncrypted(WidgetRef ref, Room room, String text) async {
    final clientMsgId = ref.read(outboxIdGenProvider)();
    final msgs = ref.read(messageStoreProvider(room.roomId).notifier);
    // Optimistic bubble immediately so the chat feels instant even when a link
    // preview fetch is in flight; the preview pops in when the server echoes
    // the stored message back.
    msgs.add(
      Msg(
        id: clientMsgId,
        from: _me,
        to: room.roomId,
        body: text,
        ts: DateTime.now().toUtc(),
        clientMsgId: clientMsgId,
        sendStatus: SendStatus.sending,
      ),
    );
    try {
      // Sender-side link preview (best-effort, bounded): the fetched title/
      // image ride inside the encrypted body, so the recipient never hits the
      // network. A slow or failing site just yields no preview.
      LinkPreview? preview;
      final url = firstUrl(text);
      if (url != null) {
        preview = await fetchLinkPreview(url)
            .timeout(const Duration(seconds: 7), onTimeout: () => null)
            .catchError((Object _) => null);
      }
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: _me,
        plaintext: TextContent(text, preview: preview).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
    } catch (e) {
      // Nothing was durably enqueued, so there's no outbox row to retry from —
      // drop the optimistic bubble rather than leaving an un-retryable failure.
      msgs.remove(clientMsgId);
      debugPrint('send failed before enqueue: $e');
      return;
    }
    // Durably enqueued. A kick failure leaves the row for the drain to retry,
    // so surface a tap-to-retry affordance.
    try {
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      msgs.updateStatus(clientMsgId, SendStatus.failed);
    }
  }

  /// Encrypt + upload an attachment, then send it as a `kind:"file"` message
  /// through the same outbox path as text. The optimistic bubble carries the
  /// locally built descriptor (incl. inline thumb) so the preview shows
  /// immediately; the authoritative row replaces it on the server echo.
  Future<void> _sendAttachment(
    WidgetRef ref,
    Room room,
    BuildContext context, {
    required Uint8List bytes,
    required String filename,
    required String mime,
    String? videoPath,
    String? caption,
  }) async {
    final clientMsgId = ref.read(outboxIdGenProvider)();
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    if (bytes.length > 256 * 1024 * 1024) {
      // Mirrors the server's MAX_ATTACHMENT_BYTES (spec §4); 256 MiB keeps the
      // ~2× in-memory decrypt peak clear of iOS jetsam.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That file is too large (max 256 MB).')),
      );
      return;
    }
    try {
      final thumb = mime.startsWith('video/') && videoPath != null
          ? await buildVideoThumbnail(videoPath)
          : await buildImageThumbnail(bytes);
      final enc = await encryptFileBytes(bytes);
      final blobKey = await uploadCiphertext(
        conn: conn,
        roomId: room.roomId,
        ciphertext: enc.ciphertext,
      );

      final descriptor = AttachmentDescriptor(
        blobKey: blobKey,
        contentKeyB64: base64.encode(enc.key),
        nonceB64: base64.encode(enc.nonce),
        mime: mime,
        filename: filename,
        size: bytes.length,
        width: thumb.width,
        height: thumb.height,
        durationMs: null, // populated for video in a follow-up if needed
        thumbB64: await encodeThumb(thumb.jpeg),
      );

      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: _me,
        plaintext: FileContent(descriptor, caption: caption).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
      ref
          .read(messageStoreProvider(room.roomId).notifier)
          .add(
            Msg(
              id: clientMsgId,
              from: _me,
              to: room.roomId,
              body: caption ?? '',
              ts: DateTime.now().toUtc(),
              clientMsgId: clientMsgId,
              sendStatus: SendStatus.sending,
              attachment: descriptor,
            ),
          );
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't send attachment.")),
      );
    }
  }

  /// Pick photos/videos/files and return them as staged items for the composer
  /// tray. Picking no longer sends — the user adds a caption and taps send,
  /// which flushes the tray through [_sendStaged].
  Future<List<StagedAttachment>> _pickMedia(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo Library'),
              onTap: () => Navigator.pop(context, 'photos'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Choose File'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    final out = <StagedAttachment>[];
    if (choice == 'photos') {
      // imageQuality forces iOS to re-encode the picked image to JPEG. iOS
      // Photos delivers HEIC, which the pure-Dart `image` package can't decode
      // (thumbnail build would throw); JPEG is decodable and universally
      // viewable. Videos picked here are unaffected by imageQuality.
      final picked = await ImagePicker().pickMultipleMedia(imageQuality: 90);
      for (final item in picked) {
        final bytes = await item.readAsBytes();
        final mime = _mimeFor(item.name, item.mimeType);
        out.add(
          StagedAttachment(
            bytes: bytes,
            filename: item.name,
            mime: mime,
            videoPath: mime.startsWith('video/') ? item.path : null,
          ),
        );
      }
    } else if (choice == 'file') {
      final res = await FilePicker.pickFiles(
        withReadStream: false,
        allowMultiple: true,
      );
      if (res == null) return out;
      for (final f in res.files) {
        if (f.path == null) continue;
        final bytes = await File(f.path!).readAsBytes();
        final mime = _mimeFor(f.name, null);
        out.add(
          StagedAttachment(
            bytes: bytes,
            filename: f.name,
            mime: mime,
            videoPath: mime.startsWith('video/') ? f.path : null,
          ),
        );
      }
    }
    return out;
  }

  /// Flush the composer's staged media. Items send in tray order; the caption
  /// (composer text) rides on the last item so a multi-pick reads as one
  /// captioned run, mirroring iMessage/Telegram.
  Future<void> _sendStaged(
    WidgetRef ref,
    Room room,
    BuildContext context,
    List<StagedAttachment> items,
    String caption,
  ) async {
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final isLast = i == items.length - 1;
      if (!context.mounted) return;
      await _sendAttachment(
        ref,
        room,
        context,
        bytes: item.bytes,
        filename: item.filename,
        mime: item.mime,
        videoPath: item.videoPath,
        caption: isLast && caption.isNotEmpty ? caption : null,
      );
    }
  }

  String _mimeFor(String name, String? hint) {
    if (hint != null && hint.isNotEmpty) return hint;
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.mov')) return 'video/mp4';
    if (lower.endsWith('.png')) return 'image/png';
    return 'image/jpeg';
  }

  Future<void> _openAttachment(
    WidgetRef ref,
    Room room,
    BuildContext context,
    AttachmentDescriptor descriptor,
  ) async {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    // A modal barrier does double duty: it blocks repeated taps (which would
    // each re-download the blob and push another viewer — the bug seen on a
    // slow video) and shows a spinner so the wait doesn't feel frozen. The
    // first open downloads + decrypts; later opens are instant (on-disk cache).
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final file = await fetchAndDecrypt(conn: conn, descriptor: descriptor);
      if (!context.mounted) return;
      Navigator.of(context).pop(); // dismiss the loader
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AttachmentViewer(file: file, descriptor: descriptor),
        ),
      );
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      debugPrint('open attachment failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open attachment: $e')),
        );
      }
    }
  }

  /// Send (or toggle off) a reaction to [targetId]. Applies optimistically to
  /// the local store, then fans the `kind:"reaction"` message out through the
  /// same persistent outbox as a normal send (no optimistic bubble — reactions
  /// aren't timeline rows). An empty [emoji] removes my reaction.
  Future<void> _sendReaction(
    WidgetRef ref,
    Room room,
    String targetId,
    String emoji,
  ) async {
    ref
        .read(messageStoreProvider(room.roomId).notifier)
        .applyReaction(targetId, _me, emoji);
    final clientMsgId = ref.read(outboxIdGenProvider)();
    try {
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: _me,
        plaintext: ReactionContent(targetId: targetId, emoji: emoji).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      debugPrint('reaction send failed: $e');
    }
  }

  /// Unsend a message for everyone. Optimistically tombstone it locally, then
  /// fan out a `kind:"delete"` control message through the same outbox path as
  /// a reaction. The partner applies the tombstone on receipt; both sides
  /// re-apply it on every reconnect (the delete replays after its target).
  Future<void> _sendDelete(WidgetRef ref, Room room, String targetId) async {
    ref
        .read(messageStoreProvider(room.roomId).notifier)
        .applyDelete(targetId, requestedBy: _me);
    final clientMsgId = ref.read(outboxIdGenProvider)();
    try {
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: _me,
        plaintext: DeleteContent(targetId: targetId).encode(),
        cache: ref.read(roomKeyCacheProvider),
        clientMsgId: clientMsgId,
      );
      final store = await ref.read(outboxStoreProvider.future);
      await store.enqueue(
        clientMsgId: clientMsgId,
        roomId: room.roomId,
        bodies: frame.bodies,
      );
      await ref.read(outboxDrainProvider).kick();
    } catch (e) {
      debugPrint('delete send failed: $e');
    }
  }

  /// Cancel an unconfirmed outgoing send (a stuck "sending" or failed bubble).
  /// Its id is the clientMsgId, so drop both the optimistic bubble and the
  /// outbox row — the server never durably stored it, so nothing replays it.
  /// (Any already-uploaded blob is left orphaned in the store; harmless.)
  Future<void> _cancelSend(WidgetRef ref, Room room, String clientMsgId) async {
    ref.read(messageStoreProvider(room.roomId).notifier).remove(clientMsgId);
    try {
      final store = await ref.read(outboxStoreProvider.future);
      await store.remove(clientMsgId);
    } catch (e) {
      debugPrint('cancel send: outbox remove failed: $e');
    }
  }

  /// Relay transient typing presence. Fire-and-forget: if the socket is down
  /// the frame is simply dropped (the receiver times its indicator out).
  void _sendTyping(WidgetRef ref, Room room, bool typing) {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    conn?.send(TypingClientFrame(roomId: room.roomId, typing: typing).toJson());
  }

  Future<void> _retry(WidgetRef ref, String clientMsgId) async {
    final store = await ref.read(outboxStoreProvider.future);
    final row = await store.lookup(clientMsgId);
    if (row == null) return;
    await store.markAttempt(clientMsgId, reset: true);
    ref
        .read(messageStoreProvider(row.roomId).notifier)
        .updateStatus(clientMsgId, SendStatus.sending);
    final drain = ref.read(outboxDrainProvider);
    // The drain's per-cycle dedup set still remembers the prior send; clear
    // just this id so the retry actually re-sends without a WS reconnect.
    drain.resetCycle(clientMsgId: clientMsgId);
    await drain.kick();
  }
}
