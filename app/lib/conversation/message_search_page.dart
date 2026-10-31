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

/// A result picked from [MessageSearchPage]: the message, and the query it
/// was found with (edited on the list, perhaps), so the chat's search mode can
/// pick up there.
typedef SearchPick = ({String messageId, String query});

/// In-channel message search results (#94): on the chat's wallpaper like the
/// chat-info page, newest first and grouped by day, with sender chips and
/// shortcuts to the photo and link galleries (#95). Reached from the chat's
/// search mode (#96) with its query filled in. Pops the tapped result as a
/// [SearchPick]; Cancel pops null.
class MessageSearchPage extends ConsumerStatefulWidget {
  const MessageSearchPage({
    super.key,
    required this.room,
    required this.selfUsername,
    this.initialQuery = '',
    this.onOpenAttachment,
  });

  final Room room;
  final String selfUsername;

  /// The query the chat was searching for when List was tapped.
  final String initialQuery;

  /// Opens a photo or video from the Photos gallery in the chat's viewer.
  /// Null leaves the gallery's tiles display-only.
  final void Function(AttachmentDescriptor descriptor)? onOpenAttachment;

  static Route<SearchPick> route({
    required Room room,
    required String selfUsername,
    String initialQuery = '',
    void Function(AttachmentDescriptor descriptor)? onOpenAttachment,
  }) => MaterialPageRoute<SearchPick>(
    builder: (_) => MessageSearchPage(
      room: room,
      selfUsername: selfUsername,
      initialQuery: initialQuery,
      onOpenAttachment: onOpenAttachment,
    ),
  );

  @override
  ConsumerState<MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends ConsumerState<MessageSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  late String _query = widget.initialQuery.trim();
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
        // Arriving with the chat's query, the results are what you came for;
        // the keyboard would cover them.
        autofocus: widget.initialQuery.isEmpty,
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
              onTap: (hit) => Navigator.of(
                context,
              ).pop<SearchPick>((messageId: hit.messageId, query: _query)),
            ),
          ),
        ],
      ),
    );
  }
}
