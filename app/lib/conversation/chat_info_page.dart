import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';
import '../calling/call_controller.dart';
import '../inbox/room.dart';
import '../profile/avatar.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import '../theme/love_toast.dart';
import '../wallpaper/wallpaper_controller.dart';
import '../wallpaper/wallpaper_screen.dart';
import '../wallpaper/wallpaper_selection.dart';
import '../wire/message.dart';
import 'chat_info_chrome.dart';
import 'message_store.dart';
import 'partner_status_line.dart';
import 'shared_media_page.dart';

/// What the chat-info page asks of the chat beneath it when it closes.
enum ChatInfoResult {
  /// The Search tile: go back to the chat in search mode (#96).
  searchInChat,
}

/// Chat-info page, reached by tapping the room name or avatar in a chat. It
/// sits on the chat's own wallpaper (#91, see [InfoScaffold]) with a header
/// (avatar, name, presence), Call / Video / Search tiles, and a Shared card
/// (#92) whose rows open the full-screen [SharedMediaPage]. All data is read
/// from the local [MessageStore]; nothing new is fetched.
class ChatInfoPage extends ConsumerWidget {
  const ChatInfoPage({
    super.key,
    required this.room,
    required this.selfUsername,
    this.onRename,
    this.onOpenAttachment,
  });

  final Room room;
  final String selfUsername;

  /// Renames the room; null when the room can't be renamed (e.g. the bare
  /// partner DM). When set, a "Rename chat" row appears here.
  final void Function(String newName)? onRename;

  /// Opens a shared photo or video in the chat's viewer (the conversation's
  /// own callback, passed through). Null leaves the thumbnails display-only.
  final void Function(AttachmentDescriptor descriptor)? onOpenAttachment;

  /// Pops [ChatInfoResult.searchInChat] from the Search tile, so the chat
  /// beneath enters search mode; pops null on a plain back.
  static Route<ChatInfoResult> route({
    required Room room,
    required String selfUsername,
    void Function(String newName)? onRename,
    void Function(AttachmentDescriptor descriptor)? onOpenAttachment,
  }) => MaterialPageRoute<ChatInfoResult>(
    builder: (_) => ChatInfoPage(
      room: room,
      selfUsername: selfUsername,
      onRename: onRename,
      onOpenAttachment: onOpenAttachment,
    ),
  );

  /// The partner's username — the room's one other member — or null.
  String? _partnerUsername() {
    for (final m in room.members) {
      if (m.username != selfUsername) return m.username;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final shared = sharedContent(ref.watch(messageStoreProvider(room.roomId)));
    final profiles = ref.watch(profileStoreProvider);
    final partner = _partnerUsername();
    final partnerProfile = partner != null
        ? profiles.forUsername(partner)
        : null;
    final partnerName = (partnerProfile?.displayName?.isNotEmpty ?? false)
        ? partnerProfile!.displayName!
        : null;
    // The partner DM is about the partner (their name, photo and presence); a
    // channel is about itself (its name, and who it's with).
    final isChannel = room.shape(selfUsername) == RoomShape.chat;
    final name = isChannel
        ? room.displayName(selfUsername)
        : partnerName ?? room.displayName(selfUsername);
    final avatarFile = !isChannel && partner != null
        ? profiles.avatarFileFor(partner)
        : null;
    // Who a channel is with: the partner's display name, else their username
    // capitalized the way the room list does it.
    final withWhom =
        partnerName ??
        (partner == null || partner.isEmpty
            ? null
            : partner[0].toUpperCase() + partner.substring(1));
    final Widget subtitle = isChannel
        ? Text(
            withWhom == null ? 'Channel' : 'Channel with $withWhom',
            key: const Key('chat-info-subtitle'),
            style: TextStyle(fontSize: 14, color: p.separatorText),
          )
        : PartnerStatusLine(
            key: const Key('chat-info-subtitle'),
            roomId: room.roomId,
            partner: partner,
            fontSize: 14,
            labelColor: p.separatorText,
          );
    return InfoScaffold(
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _header(context, name, avatarFile, subtitle),
          _actionRow(context, ref),
          _sharedSection(context, shared),
          _thisChatSection(context, ref),
          _encryptionNote(context, withWhom),
        ],
      ),
    );
  }

  /// "Photos and videos 48" (with the newest four as a strip), "Voice messages
  /// 12", "Links 9". Each row opens the [SharedMediaPage] on its kind.
  Widget _sharedSection(BuildContext context, SharedContent shared) {
    String count(List<Msg> l) => l.isEmpty ? 'None' : '${l.length}';
    void open(int tab) => Navigator.of(context).push(
      SharedMediaPage.route(
        room: room,
        initialTab: tab,
        onOpenAttachment: onOpenAttachment,
      ),
    );
    final strip = shared.media.take(4).toList();
    return InfoSection(
      caption: 'SHARED',
      children: [
        Column(
          children: [
            InfoRow(
              key: const Key('chat-info-shared-media'),
              icon: Icons.photo_outlined,
              label: 'Photos and videos',
              value: count(shared.media),
              onTap: () => open(0),
            ),
            if (strip.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Row(
                  key: const Key('chat-info-media-strip'),
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: i < strip.length
                              ? ClipRRect(
                                  key: Key('chat-info-strip-$i'),
                                  borderRadius: BorderRadius.circular(8),
                                  child: SharedMediaTile(
                                    key: sharedTileKey(strip[i]),
                                    descriptor: strip[i].attachment!,
                                    onTap: onOpenAttachment == null
                                        ? null
                                        : () => onOpenAttachment!(
                                            strip[i].attachment!,
                                          ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
        InfoRow(
          key: const Key('chat-info-shared-voice'),
          icon: Icons.mic_none,
          label: 'Voice messages',
          value: count(shared.voice),
          onTap: () => open(1),
        ),
        InfoRow(
          key: const Key('chat-info-shared-links'),
          icon: Icons.link,
          label: 'Links',
          value: count(shared.links),
          onTap: () => open(2),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    String name,
    File? avatarFile,
    Widget subtitle,
  ) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: infoCardColor(p), width: 4),
            ),
            child: Avatar(seedText: name, imageFile: avatarFile, radius: 48),
          ),
          const SizedBox(height: 10),
          Text(
            name,
            key: const Key('chat-info-name'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          subtitle,
        ],
      ),
    );
  }

  /// "This chat" (#93): the wallpaper (global, so this opens the same picker
  /// the profile page hosts) and, for a channel, Rename. The partner DM can't
  /// be renamed ([onRename] is null), since a name would turn it into a
  /// channel.
  Widget _thisChatSection(BuildContext context, WidgetRef ref) {
    final wallpaper = ref.watch(wallpaperControllerProvider).gradient;
    return InfoSection(
      caption: 'THIS CHAT',
      children: [
        InfoRow(
          key: const Key('chat-info-wallpaper'),
          icon: Icons.wallpaper_outlined,
          label: 'Wallpaper',
          value: wallpaper.label,
          onTap: () => Navigator.of(context).push(WallpaperScreen.route()),
        ),
        if (onRename != null)
          InfoRow(
            key: const Key('chat-info-rename'),
            icon: Icons.edit_outlined,
            label: 'Rename chat',
            onTap: () => _rename(context),
          ),
      ],
    );
  }

  /// One quiet line under the cards, iMessage style. Every claim holds:
  /// messages go under the room key, media under per-file keys, and calls are
  /// WebRTC (DTLS-SRTP) whose fingerprints are exchanged inside the encrypted
  /// signaling envelope, so even a TURN relay only forwards ciphertext.
  Widget _encryptionNote(BuildContext context, String? withWhom) {
    final p = context.palette;
    final who = withWhom == null ? 'you' : 'you and $withWhom';
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
      child: Row(
        key: const Key('chat-info-e2ee'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.lock_outline, size: 14, color: p.separatorText),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Messages, calls and media are end-to-end encrypted. '
              'Only $who can see them.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: p.separatorText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: room.name);
    final newName = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          key: const Key('rename-dialog-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Chat name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('rename-dialog-save'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null) return;
    onRename?.call(newName);
  }

  Widget _actionRow(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _action(
            context,
            'chat-info-call',
            Icons.call,
            'Call',
            'Calls',
            onTap: () {
              // Close the info page, then place the call — the CallOverlay shows
              // the in-app call UI once it's dialing.
              Navigator.of(context).pop();
              ref.read(callControllerProvider).placeCall(room.roomId);
            },
          ),
          const SizedBox(width: 8),
          _action(
            context,
            'chat-info-video',
            Icons.videocam,
            'Video',
            'Video calls',
            onTap: () {
              Navigator.of(context).pop();
              ref
                  .read(callControllerProvider)
                  .placeCall(room.roomId, video: true);
            },
          ),
          const SizedBox(width: 8),
          _action(
            context,
            'chat-info-search',
            Icons.search,
            'Search',
            'Search',
            // Search happens in the chat itself (#96): close this page and
            // let the conversation below switch to search mode.
            onTap: () => Navigator.of(context).pop(ChatInfoResult.searchInChat),
          ),
        ],
      ),
    );
  }

  /// One of the Call / Video / Search tiles: an equal share of the row, icon
  /// over label, at least 44pt tall.
  Widget _action(
    BuildContext context,
    String key,
    IconData icon,
    String label,
    String feature, {
    VoidCallback? onTap,
  }) {
    final p = context.palette;
    return Expanded(
      child: Material(
        color: infoCardColor(p),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key(key),
          onTap:
              onTap ?? () => showLoveToast(context, '$feature are coming soon'),
          child: SizedBox(
            height: 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: p.accentUser, size: 22),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.accentUser,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
