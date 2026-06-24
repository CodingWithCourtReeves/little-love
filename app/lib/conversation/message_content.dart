import 'dart:convert';

import '../attachment/attachment_descriptor.dart';
import 'link_preview.dart';

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
          case 'audio':
            final cap = j['caption'] as String?;
            return AudioContent(
              AttachmentDescriptor.fromJson(j),
              caption: (cap == null || cap.isEmpty) ? null : cap,
            );
          case 'reaction':
            return ReactionContent(
              targetId: (j['target'] as String?) ?? '',
              emoji: (j['emoji'] as String?) ?? '',
            );
          case 'delete':
            return DeleteContent(targetId: (j['target'] as String?) ?? '');
          case 'call':
            return CallContent(
              callId: (j['call_id'] as String?) ?? '',
              outcome: (j['outcome'] as String?) ?? 'completed',
              durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
              video: j['video'] == true,
              startedAt:
                  DateTime.tryParse(
                    (j['started_at'] as String?) ?? '',
                  )?.toUtc() ??
                  DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            );
          case 'text':
            final p = j['preview'];
            return TextContent(
              (j['text'] as String?) ?? '',
              preview: p is Map
                  ? LinkPreview.fromJson(Map<String, Object?>.from(p))
                  : null,
            );
        }
      }
    } catch (_) {
      // fall through to plain-text
    }
    return TextContent(raw);
  }
}

class TextContent extends MessageContent {
  const TextContent(this.text, {this.preview});
  final String text;

  /// Optional link preview fetched by the sender for the first URL in [text]
  /// and carried inside the encrypted body (see [LinkPreview]). Null when there
  /// is no link, or the fetch found nothing usable.
  final LinkPreview? preview;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'text',
    'text': text,
    if (preview != null) 'preview': preview!.toJson(),
  });
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

/// An unsend ("delete for everyone"): removes the message identified by
/// [targetId] from every member's timeline. Delivered as an ordinary E2EE
/// message (fanned out per recipient) referencing the target's server message
/// id; the receiver applies it as a tombstone instead of rendering a bubble,
/// so it never appears in the timeline. The server keeps the original row, but
/// it replays after the target, so each side re-applies the tombstone on
/// reconnect — no separate persistence needed.
class DeleteContent extends MessageContent {
  const DeleteContent({required this.targetId});
  final String targetId;

  @override
  String encode() => jsonEncode({'v': 1, 'kind': 'delete', 'target': targetId});
}

/// A call-log entry — the record of a completed/missed/declined call. Emitted
/// as an ordinary E2EE message through the existing send path when a call ends,
/// so it persists, syncs, badges, and replays with zero new server storage. The
/// receiver renders a call row (direction relative to `from`) and dedupes by
/// [callId] so a both-sides-emit race collapses to one entry.
class CallContent extends MessageContent {
  const CallContent({
    required this.callId,
    required this.outcome,
    required this.durationS,
    required this.startedAt,
    this.video = false,
  });

  final String callId;

  /// One of: completed, missed, declined, cancelled, busy, failed.
  final String outcome;

  /// Connected duration in seconds (0 for unconnected calls).
  final int durationS;

  /// Whether this was a video call (vs audio). Absent on the wire for audio
  /// calls (v1-compatible — older entries read as audio).
  final bool video;
  final DateTime startedAt;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'call',
    'call_id': callId,
    'outcome': outcome,
    'duration_s': durationS,
    if (video) 'video': true,
    'started_at': startedAt.toUtc().toIso8601String(),
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

/// A voice memo. Same wire shape as [FileContent] but rendered as an audio
/// player bubble. The [AttachmentDescriptor] carries the AAC `.m4a` blob key,
/// per-file key, duration, and the 64-peak waveform. Full audio bytes live in
/// R2; only the descriptor rides in the encrypted body.
class AudioContent extends MessageContent {
  const AudioContent(this.descriptor, {this.caption});
  final AttachmentDescriptor descriptor;
  final String? caption;

  @override
  String encode() => jsonEncode({
    'v': 1,
    'kind': 'audio',
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
    ...descriptor.toJson(),
  });
}
