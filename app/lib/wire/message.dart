import '../attachment/attachment_descriptor.dart';
import '../conversation/link_preview.dart';
import '../conversation/reply_ref.dart';

/// `read` means the partner has opened the chat and seen this message (the
/// double-heart state); it only ever applies to my own outgoing messages.
enum SendStatus { sent, sending, failed, read }

class Msg {
  Msg({
    required this.id,
    required this.from,
    required this.to,
    required this.body,
    required this.ts,
    this.replayed = false,
    this.clientMsgId,
    this.sendStatus = SendStatus.sent,
    this.attachment,
    this.linkPreview,
    this.reactions = const {},
    this.callOutcome,
    this.edited = false,
    this.replyTo,
  });

  final String id;
  final String from;
  final String to;

  /// Plain text Day-1a/b; a base64 ciphertext envelope Day-1c.
  /// At the Dart layer in Day-1a we treat it as opaque string.
  final String body;
  final DateTime ts;
  final bool replayed;

  /// Set on optimistic local inserts. Null for messages constructed straight
  /// from a server frame for a peer.
  final String? clientMsgId;

  final SendStatus sendStatus;

  /// Present when this message carries a `kind:"file"` attachment instead of
  /// (or alongside) text. Holds the per-file key + metadata + inline thumb.
  final AttachmentDescriptor? attachment;

  /// Present when a text message carried a link preview (see [LinkPreview]).
  /// Rides inside the encrypted body, like [attachment].
  final LinkPreview? linkPreview;

  /// Reactions on this message, keyed by reactor username → emoji. Applied from
  /// inbound `kind:"reaction"` messages (see [MessageStore.applyReaction]); not
  /// part of the wire/persisted form of this message — reactions replay as
  /// their own messages.
  final Map<String, String> reactions;

  /// Set when this message is a call-log entry (`kind:"call"`): the call outcome
  /// — completed | missed | declined | cancelled | busy | failed. Drives a
  /// distinct call-row UI (missed/declined render in red). Ingest-time only,
  /// like [attachment]; re-derived from the body on the server replay.
  final String? callOutcome;

  /// True once this text message has been edited by its author (drives the
  /// "edited" marker). Applied from inbound `kind:"edit"` messages (see
  /// [MessageStore.applyEdit]); like [reactions] it is not part of the wire/
  /// persisted form of the *message* — edits replay as their own messages.
  final bool edited;

  /// Set when this message is a reply quoting an earlier one; carried inside
  /// the encrypted body (like [linkPreview]/[attachment]) and persisted in the
  /// local cache. The UI renders a quote header from it (see [ReplyRef]).
  final ReplyRef? replyTo;

  factory Msg.fromJson(Map<String, Object?> json) {
    return Msg(
      id: json['id'] as String,
      from: json['from'] as String,
      to: json['to'] as String,
      body: json['body'] as String,
      ts: DateTime.parse(json['ts'] as String).toUtc(),
      replayed: (json['replayed'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    final m = <String, Object?>{
      'type': 'msg',
      'id': id,
      'from': from,
      'to': to,
      'body': body,
      'ts': ts.toUtc().toIso8601String(),
    };
    if (replayed) m['replayed'] = true;
    return m;
  }

  Msg copyWith({
    String? id,
    String? clientMsgId,
    SendStatus? sendStatus,
    AttachmentDescriptor? attachment,
    LinkPreview? linkPreview,
    Map<String, String>? reactions,
    String? callOutcome,
    bool? edited,
    ReplyRef? replyTo,
  }) {
    return Msg(
      id: id ?? this.id,
      from: from,
      to: to,
      body: body,
      ts: ts,
      replayed: replayed,
      clientMsgId: clientMsgId ?? this.clientMsgId,
      sendStatus: sendStatus ?? this.sendStatus,
      attachment: attachment ?? this.attachment,
      linkPreview: linkPreview ?? this.linkPreview,
      reactions: reactions ?? this.reactions,
      callOutcome: callOutcome ?? this.callOutcome,
      edited: edited ?? this.edited,
      replyTo: replyTo ?? this.replyTo,
    );
  }
}

class Hello {
  Hello({required this.since});
  final DateTime since;

  Map<String, Object?> toJson() => {
    'type': 'hello',
    'since': since.toUtc().toIso8601String(),
  };
}
