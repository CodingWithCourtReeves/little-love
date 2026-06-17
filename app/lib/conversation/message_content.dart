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
            return FileContent(AttachmentDescriptor.fromJson(j));
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

class FileContent extends MessageContent {
  const FileContent(this.descriptor);
  final AttachmentDescriptor descriptor;

  @override
  String encode() =>
      jsonEncode({'v': 1, 'kind': 'file', ...descriptor.toJson()});
}
