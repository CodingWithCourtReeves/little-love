import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../attachment/attachment_descriptor.dart';
import '../audio/playback_provider.dart';
import '../inbox/room.dart';
import '../theme/app_palette.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'audio_bubble.dart';
import 'chat_info_chrome.dart';
import 'message_store.dart';

/// A room's shared content, newest first: photos and videos ([media]), voice
/// memos ([voice]) and messages carrying a link ([links]).
typedef SharedContent = ({List<Msg> media, List<Msg> voice, List<Msg> links});

/// Sorts [messages] (oldest first, as the store keeps them) into
/// [SharedContent]. The store holds the room's whole history once the router
/// has hydrated it from `MessageDb` (it loads every row and never trims), so
/// these lists and their counts cover the full room, not a recent window.
///
/// A failed send is left out: it never reached the partner, so it isn't
/// shared. A send still in flight stays in, since it's on its way (dropping it
/// would make the count blink on every send).
SharedContent sharedContent(List<Msg> messages) {
  final shared = [
    for (final m in messages.reversed)
      if (m.sendStatus != SendStatus.failed) m,
  ];
  return (
    media: [
      for (final m in shared)
        if (m.attachment != null && !m.attachment!.isAudio) m,
    ],
    voice: [
      for (final m in shared)
        if (m.attachment != null && m.attachment!.isAudio) m,
    ],
    links: [
      for (final m in shared)
        if (linkUrlOf(m) != null) m,
    ],
  );
}

/// Identity for a shared tile: its message, as it survives the
/// optimistic-to-server-id swap. A [SharedMediaTile] keeps its decoded
/// thumbnail for its whole life, so it MUST be keyed by message, never by
/// position: the lists are newest first and live, and a positional tile would
/// keep showing the old photo while opening the one now in its slot.
Key sharedTileKey(Msg m) => ValueKey('shared-media-${m.clientMsgId ?? m.id}');

/// Full-screen gallery of a room's shared content (#92), opened from the
/// chat-info page's Shared card: Photos / Voice / Links as a segmented
/// control, each with the whole screen.
class SharedMediaPage extends ConsumerWidget {
  const SharedMediaPage({
    super.key,
    required this.room,
    this.initialTab = 0,
    this.onOpenAttachment,
    this.imagesOnly = false,
  });

  final Room room;

  /// Pick mode: only the Photos tab, with videos left out. Tapping a photo
  /// calls [onOpenAttachment].
  final bool imagesOnly;

  /// 0 Photos, 1 Voice, 2 Links.
  final int initialTab;

  /// Opens a photo or video in the chat's viewer. Null leaves tiles
  /// display-only.
  final void Function(AttachmentDescriptor descriptor)? onOpenAttachment;

  static Route<void> route({
    required Room room,
    int initialTab = 0,
    void Function(AttachmentDescriptor descriptor)? onOpenAttachment,
  }) => MaterialPageRoute<void>(
    builder: (_) => SharedMediaPage(
      room: room,
      initialTab: initialTab,
      onOpenAttachment: onOpenAttachment,
    ),
  );

  /// A page that picks one photo (no videos) and pops its descriptor.
  static Route<AttachmentDescriptor> pickPhotoRoute({required Room room}) =>
      MaterialPageRoute<AttachmentDescriptor>(
        builder: (context) => SharedMediaPage(
          room: room,
          imagesOnly: true,
          onOpenAttachment: (d) => Navigator.of(context).pop(d),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final shared = sharedContent(ref.watch(messageStoreProvider(room.roomId)));
    if (imagesOnly) {
      return InfoScaffold(
        title: 'Choose a photo',
        body: _mediaTab(context, [
          for (final m in shared.media)
            if (!m.attachment!.isVideo) m,
        ], empty: 'No photos yet'),
      );
    }
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: InfoScaffold(
        title: 'Shared',
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Container(
                height: 36,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: infoCardColor(p),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TabBar(
                  key: const Key('shared-tabs'),
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: p.accentUser,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  labelColor: p.brightness == Brightness.dark
                      ? p.bgCanvas
                      : Colors.white,
                  unselectedLabelColor: p.textPrimary,
                  labelStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const [
                    Tab(text: 'Photos'),
                    Tab(text: 'Voice'),
                    Tab(text: 'Links'),
                  ],
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _mediaTab(context, shared.media),
                  _voiceTab(context, ref, shared.voice),
                  _linksTab(context, shared.links),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mediaTab(
    BuildContext context,
    List<Msg> media, {
    String empty = 'No photos or videos yet',
  }) {
    if (media.isEmpty) return _emptyTab(context, empty);
    return GridView.builder(
      key: const Key('chat-info-media-grid'),
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: media.length,
      itemBuilder: (_, i) {
        final d = media[i].attachment!;
        // The positional key is only for finding a slot in tests; the tile
        // inside is keyed by its message (see [sharedTileKey]).
        return KeyedSubtree(
          key: Key('chat-info-media-$i'),
          child: SharedMediaTile(
            key: sharedTileKey(media[i]),
            descriptor: d,
            onTap: onOpenAttachment == null ? null : () => onOpenAttachment!(d),
          ),
        );
      },
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
        final url = linkUrlOf(m)!;
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
            style: TextStyle(color: p.separatorText, fontSize: 12),
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
        style: TextStyle(color: context.palette.separatorText, fontSize: 14),
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
String? linkUrlOf(Msg m) {
  final preview = m.linkPreview?.url;
  if (preview != null && preview.isNotEmpty) return preview;
  return _urlPattern.firstMatch(m.body)?.group(0);
}

final RegExp _urlPattern = RegExp(
  r'(https?://[^\s]+)|(\bwww\.[^\s]+)',
  caseSensitive: false,
);

/// A photo or video tile: the inline encrypted thumbnail decoded to bytes,
/// with a play badge over videos. Tapping calls [onTap] (opens it in the
/// chat's viewer); null leaves it display-only.
class SharedMediaTile extends StatefulWidget {
  const SharedMediaTile({super.key, required this.descriptor, this.onTap});

  final AttachmentDescriptor descriptor;
  final VoidCallback? onTap;

  @override
  State<SharedMediaTile> createState() => _SharedMediaTileState();
}

class _SharedMediaTileState extends State<SharedMediaTile> {
  late final Future<Uint8List> _bytes = decodeThumb(widget.descriptor.thumbB64);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: DecoratedBox(
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
      ),
    );
  }
}
