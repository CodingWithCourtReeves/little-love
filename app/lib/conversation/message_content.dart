import 'dart:convert';

import '../attachment/attachment_descriptor.dart';

/// The decrypted plaintext layer of a message (spec §3). Versioned so future
/// kinds can be added. Text and file are the only kinds in this iteration.
sealed class MessageContent {
  const MessageContent();

  String encode();

  /// Decode a decrypted plaintext string. Any string that is not a valid v1
  /// envelope is treated as legacy/plain text (back-compat with pre-envelope
  /// sends and with the cannot-decrypt sentinel, which renders as text).
  static MessageContent decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, Object?> && j['v'] == 1) {
        switch (j['kind']) {
          case 'file':
            final cap = j['caption'] as String?;
            return FileContent(
              AttachmentDescriptor.fromJson(j),
              caption: (cap == null || cap.isEmpty) ? null : cap,
            );
          case 'reaction':
            return ReactionContent(
              targetId: (j['target'] as String?) ?? '',
              emoji: (j['emoji'] as String?) ?? '',
            );
          case 'text':
            return TextContent((j['text'] as String?) ?? '');
        }
      }
    } catch (_) {
      // fall through to plain-text
    }
    return TextContent(raw);
  }
}

class TextContent extends MessageContent {
  const TextContent(this.text);
  final String text;

  @override
  String encode() => jsonEncode({'v': 1, 'kind': 'text', 'text': text});
}

/// A reaction to another message in the room. It is delivered as an ordinary
/// E2EE message (fanned out per recipient) referencing the target's server
/// message id; the receiver applies it onto the target instead of rendering a
/// bubble, so reactions never appear in the timeline or bump unread state. An
/// empty [emoji] removes this sender's reaction (toggle off).
class ReactionContent extends MessageContent {
  const ReactionContent({required this.targetId, required this.emoji});
  final String targetId;
  final String emoji;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'reaction',
    'target': targetId,
    'emoji': emoji,
  });
}

class FileContent extends MessageContent {
  const FileContent(this.descriptor, {this.caption});
  final AttachmentDescriptor descriptor;

  /// Optional text sent alongside the file, rendered as a caption under the
  /// media tile (one bubble). Null/empty when the attachment has no caption.
  final String? caption;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'file',
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
    ...descriptor.toJson(),
  });
}
