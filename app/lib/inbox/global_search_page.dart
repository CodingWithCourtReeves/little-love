import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_search.dart';
import '../conversation/message_search_page.dart';
import '../identity/providers.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import 'inbox_state.dart';
import 'room.dart';

/// Global (cross-room) message search from the chat-rooms list. Results are
/// grouped by room; tapping one opens that room scrolled to the message.
class GlobalSearchPage extends ConsumerStatefulWidget {
  const GlobalSearchPage({super.key, required this.onOpen});

  /// Open [messageId] in [roomId] (the caller pops this page + focuses it).
  final void Function(String roomId, String messageId) onOpen;

  static Route<void> route({
    required void Function(String roomId, String messageId) onOpen,
  }) =>
      MaterialPageRoute<void>(builder: (_) => GlobalSearchPage(onOpen: onOpen));

  @override
  ConsumerState<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends ConsumerState<GlobalSearchPage> {
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

  /// The room's display name for a result section header.
  String _roomName(String roomId, List<Room> rooms, String self) {
    Room? room;
    for (final r in rooms) {
      if (r.roomId == roomId) {
        room = r;
        break;
      }
    }
    if (room == null) return roomId;
    String? partner;
    for (final m in room.members) {
      if (m.username != self) {
        partner = m.username;
        break;
      }
    }
    final profileName = partner == null
        ? null
        : ref.read(profileStoreProvider).forUsername(partner)?.displayName;
    return (profileName?.isNotEmpty ?? false)
        ? profileName!
        : room.displayName(self);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final self = ref.watch(accountProvider).valueOrNull?.username ?? '';
    final rooms = ref.watch(inboxStateProvider).rooms;
    final results = ref.watch(globalSearchProvider(_query));
    return Scaffold(
      backgroundColor: p.bgCanvas,
      appBar: AppBar(
        backgroundColor: p.bgCanvas,
        title: TextField(
          key: const Key('global-search-field'),
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          style: TextStyle(color: p.textPrimary, fontSize: 17),
          decoration: InputDecoration(
            hintText: 'Search all chats',
            hintStyle: TextStyle(color: p.textMuted),
            border: InputBorder.none,
          ),
        ),
      ),
      body: results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Text('Search failed', style: TextStyle(color: p.textMuted)),
        ),
        data: (hits) {
          if (hits.isEmpty) {
            return Center(
              child: Text(
                _query.isEmpty
                    ? 'Type to search all chats'
                    : 'No messages found',
                style: TextStyle(color: p.textMuted),
              ),
            );
          }
          // Group hits by room, preserving best-match order across the set.
          final grouped = <String, List<SearchHit>>{};
          for (final h in hits) {
            grouped.putIfAbsent(h.roomId, () => []).add(h);
          }
          final rows = <Widget>[];
          grouped.forEach((roomId, roomHits) {
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  _roomName(roomId, rooms, self),
                  style: TextStyle(
                    color: p.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            );
            for (final hit in roomHits) {
              rows.add(
                ListTile(
                  key: Key('global-result-${hit.messageId}'),
                  title: Text(
                    hit.from == self ? 'You' : hit.from,
                    style: TextStyle(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: SnippetText(snippetHtml: hit.snippetHtml),
                  onTap: () => widget.onOpen(hit.roomId, hit.messageId),
                ),
              );
            }
          });
          return ListView(
            key: const Key('global-search-results'),
            children: rows,
          );
        },
      ),
    );
  }
}
