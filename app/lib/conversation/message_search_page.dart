import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inbox/room.dart';
import '../theme/app_palette.dart';
import 'message_search.dart';

/// In-channel message search. Reached from the chat-info 🔍 action. Pops the
/// tapped result's message id so the conversation can scroll to it.
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
    final p = context.palette;
    final results = ref.watch(
      channelSearchProvider((roomId: widget.room.roomId, query: _query)),
    );
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        backgroundColor: p.bgCanvas,
        title: TextField(
          key: const Key('message-search-field'),
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: p.textPrimary, fontSize: 17),
          decoration: InputDecoration(
            hintText: 'Search messages',
            hintStyle: TextStyle(color: p.textMuted),
            border: InputBorder.none,
          ),
        ),
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

/// A list of [SearchHit]s with highlighted snippets, shared by the in-channel
/// and (room-grouped) global search surfaces. Renders the async states.
class SearchResultsList extends StatelessWidget {
  const SearchResultsList({
    super.key,
    required this.results,
    required this.selfUsername,
    required this.emptyHint,
    required this.onTap,
    this.showRoom = false,
  });

  final AsyncValue<List<SearchHit>> results;
  final String selfUsername;
  final String emptyHint;
  final void Function(SearchHit hit) onTap;
  final bool showRoom;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text('Search failed', style: TextStyle(color: p.textMuted)),
      ),
      data: (hits) {
        if (hits.isEmpty) {
          return Center(
            child: Text(emptyHint, style: TextStyle(color: p.textMuted)),
          );
        }
        return ListView.builder(
          key: const Key('search-results'),
          itemCount: hits.length,
          itemBuilder: (context, i) {
            final hit = hits[i];
            final who = hit.from == selfUsername ? 'You' : hit.from;
            return ListTile(
              key: Key('search-result-${hit.messageId}'),
              title: Text(
                who,
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              subtitle: Text.rich(
                _highlight(hit.snippetHtml, p),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onTap(hit),
            );
          },
        );
      },
    );
  }
}

/// Parse FTS5 `snippet()` output (matches wrapped in `<b>…</b>`) into spans,
/// bolding + accenting the matched terms. The snippet content is our own
/// message text, and the only markup snippet() emits is the bold delimiters we
/// passed it, so a plain split is safe.
TextSpan _highlight(String snippet, AppPalette p) {
  final spans = <TextSpan>[];
  final base = TextStyle(color: p.textMuted, fontSize: 13);
  final bold = TextStyle(
    color: p.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.w700,
  );
  var rest = snippet;
  while (true) {
    final open = rest.indexOf('<b>');
    if (open < 0) {
      if (rest.isNotEmpty) spans.add(TextSpan(text: rest, style: base));
      break;
    }
    if (open > 0) {
      spans.add(TextSpan(text: rest.substring(0, open), style: base));
    }
    final close = rest.indexOf('</b>', open + 3);
    if (close < 0) {
      spans.add(TextSpan(text: rest.substring(open + 3), style: base));
      break;
    }
    spans.add(TextSpan(text: rest.substring(open + 3, close), style: bold));
    rest = rest.substring(close + 4);
  }
  return TextSpan(children: spans);
}
