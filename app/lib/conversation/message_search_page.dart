import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';
import '../inbox/room.dart';
import '../profile/profile_store.dart';
import 'chat_info_chrome.dart';
import 'chat_search_field.dart';
import 'message_search.dart';
import 'search_filter_chips.dart';
import 'search_results.dart';
import 'shared_media_page.dart';

/// In-channel message search results (#94): on the chat's wallpaper like the
/// chat-info page, newest first and grouped by day, with sender chips and
/// shortcuts to the photo and link galleries (#95). Pops the tapped result's
/// message id so the conversation can scroll to it.
class MessageSearchPage extends ConsumerStatefulWidget {
  const MessageSearchPage({
    super.key,
    required this.room,
    required this.selfUsername,
    this.onOpenAttachment,
  });

  final Room room;
  final String selfUsername;

  /// Opens a photo or video from the Photos gallery in the chat's viewer.
  /// Null leaves the gallery's tiles display-only.
  final void Function(AttachmentDescriptor descriptor)? onOpenAttachment;

  static Route<String> route({
    required Room room,
    required String selfUsername,
    void Function(AttachmentDescriptor descriptor)? onOpenAttachment,
  }) => MaterialPageRoute<String>(
    builder: (_) => MessageSearchPage(
      room: room,
      selfUsername: selfUsername,
      onOpenAttachment: onOpenAttachment,
    ),
  );

  @override
  ConsumerState<MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends ConsumerState<MessageSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  SenderFilter _sender = SenderFilter.all;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  /// The partner's username: the room's one other member, or '' if the
  /// roster hasn't loaded.
  String get _partner {
    for (final m in widget.room.members) {
      if (m.username != widget.selfUsername) return m.username;
    }
    return '';
  }

  void _openGallery(int tab) => Navigator.of(context).push(
    SharedMediaPage.route(
      room: widget.room,
      initialTab: tab,
      onOpenAttachment: widget.onOpenAttachment,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final partner = _partner;
    final from = switch (_sender) {
      SenderFilter.all => null,
      SenderFilter.partner => partner,
      SenderFilter.me => widget.selfUsername,
    };
    final results = ref.watch(
      channelSearchProvider((
        roomId: widget.room.roomId,
        query: _query,
        from: from,
      )),
    );
    final profiles = ref.watch(profileStoreProvider);
    return InfoScaffold(
      bar: ChatSearchField(
        controller: _controller,
        autofocus: true,
        onChanged: _onChanged,
        onCancel: () => Navigator.of(context).maybePop(),
      ),
      body: Column(
        children: [
          SearchFilterChips(
            partnerName: senderName(
              partner,
              self: widget.selfUsername,
              profiles: profiles,
            ),
            selected: _sender,
            onSelect: (f) => setState(() => _sender = f),
            onPhotos: () => _openGallery(0),
            onLinks: () => _openGallery(2),
          ),
          Expanded(
            child: SearchResultsList(
              results: results,
              selfUsername: widget.selfUsername,
              emptyHint: _query.isEmpty
                  ? 'Type to search this chat'
                  : 'No messages found',
              onTap: (hit) => Navigator.of(context).pop(hit.messageId),
            ),
          ),
        ],
      ),
    );
  }
}
