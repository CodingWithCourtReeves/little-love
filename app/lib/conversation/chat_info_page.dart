import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import '../wire/message.dart';
import 'audio_bubble.dart';
import 'message_store.dart';

/// Telegram-style chat-info page, reached by tapping the room name in a chat.
/// A header (avatar + name), an action row (Call / Video / Search — stubbed
/// until that infrastructure exists), and tabs over the room's shared content:
/// Media (real), Voice (real), Links (real). All data is read from the
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

  static Route<void> route({
    required Room room,
    required String selfUsername,
    void Function(String newName)? onRename,
  }) => MaterialPageRoute<void>(
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
    final avatarFile = partner != null ? profiles.avatarFileFor(partner) : null;
    final name = (partnerProfile?.displayName?.isNotEmpty ?? false)
        ? partnerProfile!.displayName!
        : room.displayName(selfUsername);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: p.bgCanvas,
        appBar: AppBar(title: const Text('Info')),
        body: Column(
          children: [
            _header(context, name, avatarFile),
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
    );
  }

  Widget _header(BuildContext context, String name, File? avatarFile) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Avatar(seedText: name, imageFile: avatarFile, radius: 42),
          const SizedBox(height: 12),
          Text(
            name,
            key: const Key('chat-info-name'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
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
        const SizedBox(width: 28),
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
        const SizedBox(width: 28),
        _action(context, 'chat-info-search', Icons.search, 'Search', 'Search'),
      ],
    );
  }

  Widget _action(
    BuildContext context,
    String key,
    IconData icon,
    String label,
    String feature, {
    VoidCallback? onTap,
  }) {
    final p = context.palette;
    return GestureDetector(
      key: Key(key),
      onTap: onTap ?? () => showLoveToast(context, '$feature are coming soon'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.bgSurfaceAlt,
            ),
            child: Icon(icon, color: p.accentUser, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(fontSize: 12, color: p.textMuted)),
        ],
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
