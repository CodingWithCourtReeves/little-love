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
