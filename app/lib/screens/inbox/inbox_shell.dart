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
import '../../outbox/outbox_drain.dart';
import '../../outbox/outbox_store.dart';
import '../../wire/message.dart';
import '../../identity/account_local.dart';
import '../../identity/current_identity.dart';
import '../../identity/keypair.dart';
import '../../inbox/drawer.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/layout_scaffold.dart';
import '../../inbox/navigation_rail.dart';
import '../../inbox/pending_invites_provider.dart';
import '../../inbox/read_state_provider.dart';
import '../../inbox/room.dart';
import '../../inbox/sidebar.dart';
import '../../push/push_bootstrap.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';
import '../create_chat/create_channel_sheet.dart';
import '../create_chat/create_chat_invite_screen.dart';
import '../create_chat/create_chat_pick_screen.dart';
import '../pair/enter_code.dart';
import '../pair/show_invite.dart';

/// Top-level inbox screen for a signed-in user. Wraps `LayoutScaffold` and
/// supplies sidebar / rail / drawer chrome around a `ConversationPage` keyed
/// by the currently selected `roomId`.
class InboxShell extends ConsumerWidget {
  const InboxShell({super.key, required this.account});

  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Activate the router + outbox drain for this signed-in session. Watching
    // (not reading) keeps them alive while InboxShell is mounted, so the
    // drain's constructor re-fires its kick on every WS-data transition —
    // i.e. the persistent outbox auto-flushes on reconnect.
    ref.watch(liveConnectionProvider).whenData((_) {
      ref.watch(roomMessageRouterProvider);
      ref.watch(outboxDrainProvider);
    });

    final inbox = ref.watch(inboxStateProvider);
    // Once a partner room exists (i.e. we're paired), bring up push: permission
    // prompt, token registration, palette key, and notification-tap routing.
    // The provider caches, so this runs exactly once per session.
    if (inbox.rooms.isNotEmpty) {
      ref.watch(pushBootstrapProvider);
    }
    final detail = _detail(context, ref, inbox.selectedRoomId, inbox.rooms);

    return LayoutScaffold(
      sidebar: Sidebar(username: account.username),
      rail: NavigationRailChrome(username: account.username),
      drawer: DrawerContent(username: account.username),
      detail: detail,
    );
  }

  Widget _detail(
    BuildContext context,
    WidgetRef ref,
    String? selectedId,
    List<Room> rooms,
  ) {
    if (rooms.isEmpty) {
      return Scaffold(
        backgroundColor: TwilightColors.bgCanvas,
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'STEP 4 OF 4 · PAIR',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.accentSage,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Invite your partner',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        height: 1.14,
                        letterSpacing: -0.6,
                        color: TwilightColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'A pairing handshake exchanges public keys directly '
                      'between your two devices. Until that happens, there is '
                      'nothing for the server to deliver.',
                      style: TwilightType.lede,
                    ),
                    const SizedBox(height: 28),
                    PairCard(account: account),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (selectedId == null) {
      final home = defaultHomeRoomId(rooms, account.username);
      if (home != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(inboxStateProvider.notifier).select(home);
          ref.read(readStateProvider.notifier).markRead(home);
        });
        // One frame of empty canvas before selection lands.
        return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
      }
      // No rooms case is handled above; this is a defensive fallback.
      return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
    }
    final room = rooms.firstWhere((r) => r.roomId == selectedId);
    // A "solo" room is one where Court is the only member AND a pending invite
    // exists for it — the user got here by tapping "Invite them with a code",
    // creating the room, then leaving the show-invite screen. Route them back
    // to the invite code instead of an empty conversation.
    final pending = ref.watch(pendingInvitesProvider);
    final dismissed = ref.watch(dismissedInvitesProvider);
    final isSolo =
        room.members.length == 1 &&
        room.members.first.username == account.username;
    if (isSolo &&
        pending.containsKey(room.roomId) &&
        !dismissed.contains(room.roomId)) {
      return CreateChatInviteScreen(
        roomId: room.roomId,
        onDone: () =>
            ref.read(dismissedInvitesProvider.notifier).dismiss(room.roomId),
      );
    }
    // Viewing a room marks it read. Done post-frame to avoid mutating a
    // provider during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readStateProvider.notifier).markRead(room.roomId);
    });
    return ConversationPage(
      key: ValueKey(selectedId),
      room: room,
      selfUsername: account.username,
      onSend: (text) => _sendEncrypted(ref, room, text),
      onRetry: (clientMsgId) => _retry(ref, clientMsgId),
      onPickMedia: () => _pickMedia(context),
      onSendMedia: (items, caption) =>
          _sendStaged(ref, room, context, items, caption),
      onReact: (targetId, emoji) => _sendReaction(ref, room, targetId, emoji),
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
      onNewChannel: () => showCreateChannelSheet(context, ref),
    );
  }

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
        from: account.username,
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
        selfUsername: account.username,
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
        selfUsername: account.username,
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
              from: account.username,
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
        .applyReaction(targetId, account.username, emoji);
    final clientMsgId = ref.read(outboxIdGenProvider)();
    try {
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: account.username,
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
        .applyDelete(targetId, requestedBy: account.username);
    final clientMsgId = ref.read(outboxIdGenProvider)();
    try {
      final me = await ref.read(currentIdentityProvider.future);
      final frame = await buildSendFrame(
        room: room,
        me: me,
        selfUsername: account.username,
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

class PairCard extends ConsumerWidget {
  const PairCard({super.key, required this.account});
  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Material(
      color: TwilightColors.bubblePartnerBg,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: TwilightColors.borderSoft),
        borderRadius: BorderRadius.all(Radius.circular(2)),
      ),
      elevation: 0,
      child: Column(
        children: [
          _PairOption(
            glyph: '+',
            title: 'Invite them with a code',
            detail: 'Generates a one-time code they enter on their device.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ShowInviteScreen()),
            ),
          ),
          const Divider(
            height: 1,
            thickness: 1,
            color: TwilightColors.borderSoft,
            indent: 18,
            endIndent: 18,
          ),
          _PairOption(
            glyph: '⌗',
            title: 'I have an invite code',
            detail: 'Enter a code your partner sent you.',
            onTap: () => _openEnterCode(context, ref),
          ),
          const Divider(
            height: 1,
            thickness: 1,
            color: TwilightColors.borderSoft,
            indent: 18,
            endIndent: 18,
          ),
          _PairOption(
            glyph: '✦',
            title: 'Create a chat',
            detail: 'Pick your partner, then send the invite.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CreateChatPickScreen(selfUsername: account.username),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openEnterCode(BuildContext context, WidgetRef ref) async {
    final DerivedIdentity identity;
    try {
      identity = await ref.read(currentIdentityProvider.future);
    } on StateError {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unlock identity — please sign in again.'),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            EnterCodeScreen(identity: identity, selfUsername: account.username),
      ),
    );
  }
}

class _PairOption extends StatelessWidget {
  const _PairOption({
    required this.glyph,
    required this.title,
    required this.detail,
    required this.onTap,
  });
  final String glyph;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                border: Border.all(color: TwilightColors.accentSage),
                borderRadius: BorderRadius.circular(2),
              ),
              alignment: Alignment.center,
              child: Text(
                glyph,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: TwilightColors.accentSage,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(detail, style: TwilightType.lede),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '→',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                color: TwilightColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
