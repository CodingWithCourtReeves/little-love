import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../attachment/attachment_descriptor.dart';
import '../inbox/room.dart';
import '../theme/app_palette.dart';
import '../theme/love_toast.dart';
import '../wire/message.dart';
import 'message_store.dart';

/// Telegram-style chat-info page, reached by tapping the room name in a chat.
/// A header (avatar + name), an action row (Call / Video / Search — stubbed
/// until that infrastructure exists), and tabs over the room's shared content:
/// Media (real), Voice (coming soon), Links (real). All data is read from the
/// local [MessageStore]; nothing new is fetched.
class ChatInfoPage extends ConsumerWidget {
  const ChatInfoPage({
    super.key,
    required this.room,
    required this.selfUsername,
  });

  final Room room;
  final String selfUsername;

  static Route<void> route({
    required Room room,
    required String selfUsername,
  }) => MaterialPageRoute<void>(
    builder: (_) => ChatInfoPage(room: room, selfUsername: selfUsername),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final messages = ref.watch(messageStoreProvider(room.roomId));
    // Newest first for both galleries.
    final media = [
      for (final m in messages.reversed)
        if (m.attachment != null) m,
    ];
    final links = [
      for (final m in messages.reversed)
        if (_linkUrl(m) != null) m,
    ];
    final name = room.displayName(selfUsername);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: p.bgCanvas,
        appBar: AppBar(title: const Text('Info')),
        body: Column(
          children: [
            _header(context, name),
            _actionRow(context),
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
                  _emptyTab(context, 'Voice messages are coming soon'),
                  _linksTab(context, links),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String name) {
    final p = context.palette;
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.accentUser.withValues(alpha: 0.18),
              border: Border.all(color: p.accentUser, width: 1.5),
            ),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w500,
                color: p.accentUser,
              ),
            ),
          ),
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

  Widget _actionRow(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _action(context, 'chat-info-call', Icons.call, 'Call', 'Calls'),
        const SizedBox(width: 28),
        _action(
          context,
          'chat-info-video',
          Icons.videocam,
          'Video',
          'Video calls',
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
    String feature,
  ) {
    final p = context.palette;
    return GestureDetector(
      key: Key(key),
      onTap: () => showLoveToast(context, '$feature are coming soon'),
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
