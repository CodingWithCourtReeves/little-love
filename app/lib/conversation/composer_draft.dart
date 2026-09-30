import 'reply_ref.dart';

/// An unsent composer state for one room: the typed text plus the message it
/// quotes, if any. Persisted to the encrypted [MessageDb] so backgrounding the
/// app or leaving the room mid-compose doesn't lose it.
///
/// Staged media is deliberately **not** part of a draft: those are raw
/// plaintext bytes (sometimes hundreds of MB), so they live in memory only
/// (see `stagedMediaProvider`) rather than being written to disk.
class ComposerDraft {
  const ComposerDraft({required this.text, this.replyTo});

  final String text;
  final ReplyRef? replyTo;

  /// Nothing worth keeping: whitespace-only text and no quoted reply. Saving an
  /// empty draft deletes the stored one.
  bool get isEmpty => text.trim().isEmpty && replyTo == null;
}
