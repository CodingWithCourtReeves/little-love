import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';
import '../conversation/draft_preview_state.dart';
import '../conversation/message_store.dart';
import '../conversation/room_hydration_state.dart';
import '../conversation/status_marker.dart';
import '../conversation/typing_state.dart';
import '../pairing/encryption.dart';
import '../wire/message.dart';
import 'read_state_provider.dart';

/// The glyph leading a preview for a message that isn't plain text.
enum PreviewIcon { photo, video, voice, call }

/// How a preview's text reads: ordinary, live (partner typing), a warning
/// (missed call), or a placeholder ("No messages yet", "Message unavailable").
enum PreviewTone { plain, live, warning, placeholder }

/// What a home-screen row says about its room: the latest message (or what
/// stands in for it), its time and my delivery mark, and the unread count.
class RoomPreview {
  const RoomPreview({
    this.text = '',
    this.icon,
    this.tone = PreviewTone.plain,
    this.fromMe = false,
    this.isDraft = false,
    this.mark,
    this.failed = false,
    this.at,
    this.unread = 0,
  });

  /// One line of preview text, whitespace collapsed. Empty while the room's
  /// history is still loading.
  final String text;
  final PreviewIcon? icon;
  final PreviewTone tone;

  /// The latest message is mine: the row prefixes "You: ".
  final bool fromMe;

  /// [text] is my unsent draft: the row prefixes "Draft: ".
  final bool isDraft;

  /// My latest message's delivery mark, shown beside the time. Null when the
  /// latest message isn't mine, or it failed (see [failed]).
  final StatusMark? mark;

  /// My latest message failed to send.
  final bool failed;

  /// When the latest message was sent (UTC). Null when there is none.
  final DateTime? at;

  final int unread;
}

/// Build a room's [RoomPreview]. Pure, so the precedence rules are testable:
/// the partner typing beats a draft, which beats the latest message.
///
/// The latest message is the newest in [messages] by timestamp. Reactions,
/// edits and unsends are applied onto existing rows rather than stored as
/// rows, so they can never become the preview, and an unsent latest message
/// is already gone, which leaves the one before it.
RoomPreview roomPreviewFor({
  required List<Msg> messages,
  required String me,
  required bool hydrated,
  required int unread,
  bool partnerTyping = false,
  String? draft,
}) {
  Msg? latest;
  for (final m in messages) {
    if (latest == null || !m.ts.isBefore(latest.ts)) latest = m;
  }
  final at = latest?.ts;
  if (partnerTyping) {
    return RoomPreview(
      text: 'typing…',
      tone: PreviewTone.live,
      at: at,
      unread: unread,
    );
  }
  if (draft != null) {
    return RoomPreview(text: draft, isDraft: true, at: at, unread: unread);
  }
  if (latest == null) {
    // Before hydration an empty store means "not loaded yet", not "empty".
    return hydrated
        ? RoomPreview(
            text: 'No messages yet',
            tone: PreviewTone.placeholder,
            unread: unread,
          )
        : RoomPreview(unread: unread);
  }
  return _describe(latest, me: me, unread: unread);
}

RoomPreview _describe(Msg m, {required String me, required int unread}) {
  if (m.body == cannotDecryptSentinel) {
    return RoomPreview(
      text: 'Message unavailable',
      tone: PreviewTone.placeholder,
      at: m.ts,
      unread: unread,
    );
  }
  final callOutcome = m.callOutcome;
  if (callOutcome != null) {
    // The body is the call-log summary ("📞 Missed call"); the row draws its
    // own phone glyph, so drop the leading emoji. Missed and declined read as
    // a warning, as they do in the chat.
    final missed = callOutcome == 'missed' || callOutcome == 'declined';
    return RoomPreview(
      text: _collapse(m.body.replaceFirst(RegExp(r'^(📞|📹)\s*'), '')),
      icon: PreviewIcon.call,
      tone: missed ? PreviewTone.warning : PreviewTone.plain,
      at: m.ts,
      unread: unread,
    );
  }
  final mine = m.from == me;
  final caption = _collapse(m.body);
  final (PreviewIcon? icon, String text) = switch (m.attachment) {
    null => (null, caption),
    AttachmentDescriptor(isAudio: true, :final durationMs) => (
      PreviewIcon.voice,
      _voiceLabel(durationMs),
    ),
    AttachmentDescriptor(isVideo: true) => (
      PreviewIcon.video,
      caption.isNotEmpty ? caption : 'Video',
    ),
    AttachmentDescriptor() => (
      PreviewIcon.photo,
      caption.isNotEmpty ? caption : 'Photo',
    ),
  };
  return RoomPreview(
    text: text,
    icon: icon,
    fromMe: mine,
    mark: mine ? _markFor(m.sendStatus) : null,
    failed: mine && m.sendStatus == SendStatus.failed,
    at: m.ts,
    unread: unread,
  );
}

StatusMark? _markFor(SendStatus status) => switch (status) {
  SendStatus.sending => StatusMark.sending,
  SendStatus.sent => StatusMark.sent,
  SendStatus.read => StatusMark.read,
  SendStatus.failed => null,
};

/// "Voice message · 0:42", or just "Voice message" when the length is unknown.
String _voiceLabel(int? durationMs) {
  if (durationMs == null || durationMs <= 0) return 'Voice message';
  final s = (durationMs / 1000).round();
  return 'Voice message · ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Newlines and runs of spaces become single spaces, so a multi-line message
/// previews as flowing text.
String _collapse(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A room's [RoomPreview], recomputed only when one of its inputs changes
/// (that room's messages, read marker, typing signal, draft or hydration), not
/// on every home-screen rebuild. Keyed by the (me, roomId) record.
final roomPreviewProvider =
    Provider.family<RoomPreview, ({String me, String roomId})>(
      (ref, key) => roomPreviewFor(
        messages: ref.watch(messageStoreProvider(key.roomId)),
        me: key.me,
        hydrated: ref.watch(roomHydratedProvider(key.roomId)),
        unread: ref.watch(roomUnreadCountProvider(key)),
        partnerTyping: ref.watch(typingProvider(key.roomId)),
        draft: ref.watch(draftPreviewProvider(key.roomId)),
      ),
    );
