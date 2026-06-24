import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'message_db.dart';

/// In-channel search: ranked hits within [roomId] for [query]. Empty query →
/// empty (so the results list clears as the field empties).
final channelSearchProvider =
    FutureProvider.family<List<SearchHit>, ({String roomId, String query})>((
      ref,
      a,
    ) async {
      if (a.query.trim().isEmpty) return const [];
      final db = await ref.watch(messageDbProvider.future);
      return db.search(a.query, roomId: a.roomId);
    });

/// Global search: ranked hits across every room for [query].
final globalSearchProvider = FutureProvider.family<List<SearchHit>, String>((
  ref,
  query,
) async {
  if (query.trim().isEmpty) return const [];
  final db = await ref.watch(messageDbProvider.future);
  return db.search(query);
});

/// One ranked search result over the local message store.
class SearchHit {
  const SearchHit({
    required this.messageId,
    required this.roomId,
    required this.from,
    required this.ts,
    required this.snippetHtml,
    required this.body,
  });

  final String messageId;
  final String roomId;
  final String from;
  final DateTime ts;

  /// The body with matched terms wrapped in `<b>…</b>` (from FTS5 `snippet()`),
  /// for the result-row highlight.
  final String snippetHtml;

  /// The full plaintext body, for rendering / jump-to-message.
  final String body;
}
