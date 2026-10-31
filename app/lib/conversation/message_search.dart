import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'message_db.dart';

/// How [MessageDb.search] orders its hits.
enum SearchOrder {
  /// BM25 relevance with a slight nudge toward newer messages.
  relevance,

  /// Newest first.
  newest,
}

/// The most hits one in-chat search returns: the newest this many matches.
/// Higher than the global cap because the in-chat results are scanned by date
/// and stepped through one by one, so a common word ("love") between two people
/// should still reach well back.
const int channelSearchLimit = 200;

/// In-channel search: hits within [roomId] for [query], newest first (#94),
/// and only [from]'s messages when set (#95). In one chat between two people,
/// when something was said is what you scan by, so date order beats relevance
/// here. Empty query → empty (so the results list clears as the field
/// empties). Auto-disposed, so reopening the list runs the query again and
/// picks up messages that arrived since.
final channelSearchProvider = FutureProvider.autoDispose
    .family<List<SearchHit>, ({String roomId, String query, String? from})>((
      ref,
      a,
    ) async {
      final db = await ref.watch(messageDbProvider.future);
      return searchChannel(db, roomId: a.roomId, query: a.query, from: a.from);
    });

/// One in-chat search: [roomId]'s hits for [query], newest first, at most
/// [channelSearchLimit], only [from]'s when set. Empty query → empty. The
/// chat's own search mode (#96) calls this directly rather than through
/// [channelSearchProvider]'s cache, so a message that arrived since an earlier
/// identical query still shows up.
Future<List<SearchHit>> searchChannel(
  MessageDb db, {
  required String roomId,
  required String query,
  String? from,
}) async {
  if (query.trim().isEmpty) return const [];
  return db.search(
    query,
    roomId: roomId,
    from: from,
    limit: channelSearchLimit,
    order: SearchOrder.newest,
  );
}

/// Global search: ranked hits across every room for [query]. Stays in
/// relevance order: it groups hits by room and orders the rooms by their best
/// match, which date order would turn into "the room with the newest hit".
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
