/// A reference to the message a reply quotes. Rides inside the encrypted body
/// of a text/file/audio send (see [MessageContent]). The receiver renders a
/// quote from this snippet, but never *acts* on [id] — so unlike delete/edit
/// there is no privileged action to authorize at the apply layer. When the
/// target is in the buffer the UI prefers the live message (reflecting later
/// edits); this cached snippet is the fallback when the target is not loaded.
class ReplyRef {
  const ReplyRef({
    required this.id,
    required this.author,
    required this.kind,
    this.text,
  });

  /// Target message's server id (used for tap-to-jump via `_focusMessage`).
  final String id;

  /// Target's `from` username — the quote's attribution label.
  final String author;

  /// One of: text | photo | video | voice | file. Lets the quote render
  /// "Photo" / "Voice message" without an excerpt.
  final String kind;

  /// A short excerpt (<=140 chars), present only for text messages (and
  /// captioned media). Null for bare media references.
  final String? text;

  Map<String, Object?> toJson() => {
    'id': id,
    'author': author,
    'kind': kind,
    if (text != null && text!.isNotEmpty) 'text': text,
  };

  factory ReplyRef.fromJson(Map<String, Object?> j) => ReplyRef(
    id: (j['id'] as String?) ?? '',
    author: (j['author'] as String?) ?? '',
    kind: (j['kind'] as String?) ?? 'text',
    text: j['text'] as String?,
  );
}
