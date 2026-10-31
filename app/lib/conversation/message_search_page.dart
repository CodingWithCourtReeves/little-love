import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inbox/room.dart';
import 'chat_info_chrome.dart';
import 'chat_search_field.dart';
import 'message_search.dart';
import 'search_results.dart';

/// In-channel message search results (#94): on the chat's wallpaper like the
/// chat-info page, newest first and grouped by day. Pops the tapped result's
/// message id so the conversation can scroll to it.
class MessageSearchPage extends ConsumerStatefulWidget {
  const MessageSearchPage({
    super.key,
    required this.room,
    required this.selfUsername,
  });

  final Room room;
  final String selfUsername;

  static Route<String> route({
    required Room room,
    required String selfUsername,
  }) => MaterialPageRoute<String>(
    builder: (_) => MessageSearchPage(room: room, selfUsername: selfUsername),
  );

  @override
  ConsumerState<MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends ConsumerState<MessageSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

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

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(
      channelSearchProvider((roomId: widget.room.roomId, query: _query)),
    );
    return InfoScaffold(
      bar: ChatSearchField(
        controller: _controller,
        autofocus: true,
        onChanged: _onChanged,
        onCancel: () => Navigator.of(context).maybePop(),
      ),
      body: SearchResultsList(
        results: results,
        selfUsername: widget.selfUsername,
        emptyHint: _query.isEmpty
            ? 'Type to search this chat'
            : 'No messages found',
        onTap: (hit) => Navigator.of(context).pop(hit.messageId),
      ),
    );
  }
}
