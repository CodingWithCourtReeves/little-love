import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../attachment/attachment_descriptor.dart';
import '../audio/playback_provider.dart';
import '../calling/call_controller.dart';
import '../inbox/room.dart';
import '../profile/avatar.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import '../theme/love_toast.dart';
import '../wire/live_connection.dart';
import '../wallpaper/wallpaper_background.dart';
import '../wire/message.dart';
import 'audio_bubble.dart';
import 'message_search_page.dart';
import 'message_store.dart';
import 'partner_status_line.dart';

/// Chat-info page, reached by tapping the room name or avatar in a chat. It
/// sits on the chat's own wallpaper (#91) under a [veilAlpha] veil, with a
/// header (avatar, name, presence), Call / Video / Search tiles, and tabs over
/// the room's shared content (Media, Voice, Links). All data is read from the
/// local [MessageStore]; nothing new is fetched.
class ChatInfoPage extends ConsumerWidget {
  const ChatInfoPage({
    super.key,
    required this.room,
    required this.selfUsername,
    this.onRename,
  });

  final Room room;
  final String selfUsername;

  /// Renames the room; null when the room can't be renamed (e.g. the bare
  /// partner DM). When set, a "Rename chat" row appears here.
  final void Function(String newName)? onRename;

  /// Opacity of the `bgCanvas` veil over the wallpaper. Bare text can't reach
  /// 4.5:1 on any shipped wallpaper (Twilight is mid-tone), so the page tones
  /// the wallpaper down instead: at this strength `textPrimary` and
  /// `separatorText` pass everywhere (checked in `chat_info_page_test.dart`).
  static const double veilAlpha = 0.6;

  /// Opacity of the frosted cards and tiles that sit on the veil.
  static const double cardAlpha = 0.85;

  /// The fill of a card or tile on this page.
  static Color cardColor(AppPalette p) =>
      p.bubblePartnerBg.withValues(alpha: cardAlpha);

  /// Pops a message id when the user picks an in-channel search result (so the
  /// conversation beneath can scroll to it); pops null on a plain back.
  static Route<String> route({
    required Room room,
    required String selfUsername,
    void Function(String newName)? onRename,
  }) => MaterialPageRoute<String>(
    builder: (_) => ChatInfoPage(
      room: room,
      selfUsername: selfUsername,
      onRename: onRename,
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
    final messages = ref.watch(messageStoreProvider(room.roomId));
    // Newest first for both galleries.
    final media = [
      for (final m in messages.reversed)
        if (m.attachment != null && !m.attachment!.isAudio) m,
    ];
    final voice = [
      for (final m in messages.reversed)
        if (m.attachment != null && m.attachment!.isAudio) m,
    ];
    final links = [
      for (final m in messages.reversed)
        if (_linkUrl(m) != null) m,
    ];
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
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          // Status-bar icons follow the palette, which follows the wallpaper.
          systemOverlayStyle: p.brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          leading: Navigator.of(context).canPop()
              ? IconButton(
                  key: const Key('chat-info-back'),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cardColor(p),
                    ),
                    child: Icon(
                      Icons.arrow_back_ios_new,
                      color: p.textPrimary,
                      size: 18,
                    ),
                  ),
                )
              : null,
        ),
        body: WallpaperBackground(
          // A Material (not a ColoredBox) so the rows' ink paints on the veil
          // rather than under it.
          child: Material(
            color: p.bgCanvas.withValues(alpha: veilAlpha),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _header(context, name, avatarFile, subtitle),
                  _actionRow(context, ref),
                  const SizedBox(height: 8),
                  _settings(context),
                  const SizedBox(height: 8),
                  TabBar(
                    labelColor: p.accentUser,
                    unselectedLabelColor: p.textMuted,
                    indicatorColor: p.accentUser,
                    // Drop M3's full-width divider line under the tabs.
                    dividerColor: Colors.transparent,
                    tabs: const [
                      Tab(text: 'Media'),
                      Tab(text: 'Voice'),
                      Tab(text: 'Links'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _mediaTab(context, media),
                        _voiceTab(context, ref, voice),
                        _linksTab(context, links),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
              border: Border.all(color: cardColor(p), width: 4),
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

  /// Room settings moved off the chat header. Rename only — wallpaper lives on
  /// the profile page, not here.
  Widget _settings(BuildContext context) {
    final p = context.palette;
    if (onRename == null) return const SizedBox.shrink();
    return ListTile(
      key: const Key('chat-info-rename'),
      leading: Icon(Icons.edit_outlined, color: p.accentUser),
      title: const Text('Rename chat'),
      onTap: () => _rename(context),
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
            onTap: () async {
              final messageId = await Navigator.of(context).push(
                MessageSearchPage.route(room: room, selfUsername: selfUsername),
              );
              if (messageId == null) return;
              // Pop the info page with the chosen id; the conversation below
              // receives it and scrolls to that message.
              if (context.mounted) Navigator.of(context).pop(messageId);
            },
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
        color: cardColor(p),
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

  Widget _mediaTab(BuildContext context, List<Msg> media) {
    if (media.isEmpty) return _emptyTab(context, 'No media yet');
    return GridView.builder(
      key: const Key('chat-info-media-grid'),
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: media.length,
      itemBuilder: (_, i) => _MediaTile(
        key: Key('chat-info-media-$i'),
        descriptor: media[i].attachment!,
      ),
    );
  }

  Widget _voiceTab(BuildContext context, WidgetRef ref, List<Msg> voice) {
    if (voice.isEmpty) return _emptyTab(context, 'No voice messages yet');
    final controller = ref.read(voicePlaybackControllerProvider);
    final conn = ref.read(liveConnectionProvider).asData?.value;
    return ListView.builder(
      key: const Key('chat-info-voice-list'),
      itemCount: voice.length,
      itemBuilder: (_, i) => ListTile(
        key: Key('chat-info-voice-$i'),
        title: AudioBubble(
          descriptor: voice[i].attachment!,
          isMe: false,
          controller: controller,
          conn: conn,
        ),
      ),
    );
  }

  Widget _linksTab(BuildContext context, List<Msg> links) {
    if (links.isEmpty) return _emptyTab(context, 'No links yet');
    final p = context.palette;
    return ListView.separated(
      key: const Key('chat-info-links-list'),
      itemCount: links.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: p.borderSoft),
      itemBuilder: (_, i) {
        final m = links[i];
        final url = _linkUrl(m)!;
        final title = m.linkPreview?.title?.trim();
        return ListTile(
          key: Key('chat-info-link-$i'),
          leading: _linkLeading(p, m.linkPreview?.imageB64),
          title: Text(
            (title != null && title.isNotEmpty) ? title : url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textPrimary, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textMuted, fontSize: 12),
          ),
          onTap: () => _open(url),
        );
      },
    );
  }

  /// Leading thumbnail for a link row: the link preview's image when it has
  /// one, else the default link icon.
  Widget _linkLeading(AppPalette p, String? imageB64) {
    Uint8List? bytes;
    if (imageB64 != null && imageB64.isNotEmpty) {
      try {
        bytes = base64.decode(imageB64);
      } catch (_) {
        bytes = null;
      }
    }
    final icon = SizedBox(
      width: 40,
      height: 40,
      child: Icon(Icons.link, color: p.accentUser),
    );
    if (bytes == null) return icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => icon,
      ),
    );
  }

  Widget _emptyTab(BuildContext context, String message) {
    return Center(
      child: Text(
        message,
        style: TextStyle(color: context.palette.textMuted, fontSize: 14),
      ),
    );
  }

  Future<void> _open(String url) async {
    final normalized = url.startsWith('http') ? url : 'https://$url';
    final uri = Uri.tryParse(normalized);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// First URL in a message — from its fetched link preview if present, else a
/// loose scan of the body. Null when the message carries no link.
String? _linkUrl(Msg m) {
  final preview = m.linkPreview?.url;
  if (preview != null && preview.isNotEmpty) return preview;
  return _urlPattern.firstMatch(m.body)?.group(0);
}

final RegExp _urlPattern = RegExp(
  r'(https?://[^\s]+)|(\bwww\.[^\s]+)',
  caseSensitive: false,
);

/// A single media tile: the inline encrypted thumbnail decoded to bytes, with a
/// play badge over videos. Display-only for now (no full-screen viewer yet).
class _MediaTile extends StatefulWidget {
  const _MediaTile({super.key, required this.descriptor});
  final AttachmentDescriptor descriptor;
  @override
  State<_MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<_MediaTile> {
  late final Future<Uint8List> _bytes = decodeThumb(widget.descriptor.thumbB64);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(color: p.bgSurfaceAlt),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List>(
            future: _bytes,
            builder: (_, snap) {
              if (snap.hasData) {
                return Image.memory(
                  snap.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                );
              }
              return const SizedBox.shrink();
            },
          ),
          if (widget.descriptor.isVideo)
            const Center(
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 32,
              ),
            ),
        ],
      ),
    );
  }
}
