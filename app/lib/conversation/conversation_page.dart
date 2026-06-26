import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../calling/call_controller.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:linkify/linkify.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_download.dart';
import '../attachment/media_actions.dart';
import '../attachment/staged_attachment.dart';
import '../attachment/thumbnail.dart';
import '../audio/playback_provider.dart';
import '../audio/recorder_controller.dart';
import '../audio/waveform.dart';
import '../identity/providers.dart';
import '../inbox/active_room_provider.dart';
import '../inbox/read_state_provider.dart';
import '../inbox/room.dart';
import '../inbox/select_room.dart';
import '../profile/avatar.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import '../theme/love_toast.dart';
import '../wallpaper/wallpaper_background.dart';
import '../wallpaper/wallpaper_controller.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'audio_bubble.dart';
import 'chat_info_page.dart';
import 'link_preview.dart';
import 'last_seen_label.dart';
import 'message_db.dart';
import 'message_store.dart';
import 'presence_state.dart';
import 'recording_overlay.dart';
import 'reply_ref.dart';
import 'typing_state.dart';

typedef SendCallback = void Function(String text, ReplyRef? replyTo);
typedef RenameCallback = void Function(String newName);
typedef RetryCallback = void Function(String clientMsgId);
typedef OpenAttachmentCallback = void Function(AttachmentDescriptor descriptor);
typedef ReactCallback = void Function(String targetMessageId, String emoji);

/// Quick-tap reactions in the long-press bar, Telegram style. The first is the
/// double-tap default.
const _quickReactions = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

/// The soft circular chip behind a header action icon (video/audio call).
Widget _headerCircleIcon(BuildContext context, IconData icon) => Container(
  width: 34,
  height: 34,
  alignment: Alignment.center,
  decoration: BoxDecoration(
    shape: BoxShape.circle,
    color: context.palette.bgSurface.withValues(alpha: 0.7),
  ),
  child: Icon(icon, color: context.palette.textMuted, size: 20),
);

class _SendIntent extends Intent {
  const _SendIntent();
}

sealed class _Item {
  const _Item();
}

class _BubbleItem extends _Item {
  const _BubbleItem(this.msg);
  final Msg msg;
}

class _DayItem extends _Item {
  const _DayItem(this.day);
  final DateTime day;
}

class _GapItem extends _Item {
  const _GapItem(this.time);
  final DateTime time;
}

/// Per-message status marker drawn inside my own bubble, Telegram style: a
/// heart once the server acks (sent), a double heart once the partner opens the
/// chat (read), a clock while still in flight (sending). Failed sends are not
/// in-bubble — they collapse to a caption below the run.
enum _Marker { sent, sending, read }

class _StatusModel {
  const _StatusModel(this.inBubble, this.failedRun);

  /// Marker to draw inside each of my non-failed bubbles, keyed by message id.
  final Map<String, _Marker> inBubble;

  /// For every run that contains a failure, the run's trailing message id maps
  /// to the clientMsgIds of all failed messages in that run — so one tap on the
  /// caption retries the whole stack.
  final Map<String, List<String>> failedRun;
}

/// How much larger inline emoji render than the surrounding text. iMessage
/// shows emoji noticeably bigger than the words around them; this is the knob
/// to tune that against it.
const double _inlineEmojiScale = 1.3;

/// True when rune [r] is in an emoji-ish codepoint range, or is a ZWJ /
/// variation-selector / skin-tone modifier that only appears inside an emoji.
bool _runeIsEmoji(int r) =>
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x1F300 && r <= 0x1F6FF) ||
    (r >= 0x1F900 && r <= 0x1F9FF) ||
    (r >= 0x1FA70 && r <= 0x1FAFF) ||
    (r >= 0x1F1E6 && r <= 0x1F1FF) ||
    (r >= 0x1F3FB && r <= 0x1F3FF) ||
    r == 0x200D ||
    r == 0xFE0F;

/// True when grapheme cluster [g] renders as an emoji (any constituent rune is
/// emoji-ish), so it should be sized up inline.
bool _graphemeIsEmoji(String g) => g.runes.any(_runeIsEmoji);

/// Split [text] into spans, rendering runs of emoji [_inlineEmojiScale]× larger
/// than the surrounding words. Consecutive emoji/text are grouped so we emit as
/// few spans as possible. Shared by the bubble body and the live composer so
/// what you type matches what you send.
List<InlineSpan> _emojiAwareSpans(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final emojiStyle = base.copyWith(
    fontSize: (base.fontSize ?? 14) * _inlineEmojiScale,
  );
  final run = StringBuffer();
  bool? runIsEmoji;
  void flush() {
    if (run.isEmpty) return;
    spans.add(
      TextSpan(text: run.toString(), style: runIsEmoji! ? emojiStyle : base),
    );
    run.clear();
  }

  for (final g in text.characters) {
    final isEmoji = _graphemeIsEmoji(g);
    if (runIsEmoji != null && isEmoji != runIsEmoji) flush();
    runIsEmoji = isEmoji;
    run.write(g);
  }
  flush();
  return spans;
}

/// Composer controller that renders emoji larger than the surrounding text as
/// you type, mirroring the sent bubble (and iMessage). Overriding
/// [buildTextSpan] is the supported hook for styled runs inside a [TextField].
class _EmojiComposerController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    return TextSpan(style: base, children: _emojiAwareSpans(text, base));
  }
}

/// A message bubble's text: linkified (tappable URLs) with emoji runs sized up
/// inline, the way iMessage shows emoji bigger than the words around them.
///
/// Stateful because each link needs a [TapGestureRecognizer], which must be
/// disposed; building the spans once and rebuilding only when the body/styles
/// change keeps recognizers from leaking on every parent rebuild.
class _MessageBody extends StatefulWidget {
  const _MessageBody({
    required this.body,
    required this.baseStyle,
    required this.linkStyle,
    required this.onOpenUrl,
  });

  final String body;
  final TextStyle baseStyle;
  final TextStyle linkStyle;
  final void Function(String url) onOpenUrl;

  @override
  State<_MessageBody> createState() => _MessageBodyState();
}

class _MessageBodyState extends State<_MessageBody> {
  final _recognizers = <TapGestureRecognizer>[];
  late TextSpan _span;

  @override
  void initState() {
    super.initState();
    _span = _build();
  }

  @override
  void didUpdateWidget(_MessageBody old) {
    super.didUpdateWidget(old);
    if (old.body != widget.body ||
        old.baseStyle != widget.baseStyle ||
        old.linkStyle != widget.linkStyle) {
      _disposeRecognizers();
      _span = _build();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TextSpan _build() {
    final elements = linkify(
      widget.body,
      options: const LinkifyOptions(humanize: false, looseUrl: true),
    );
    final children = <InlineSpan>[];
    for (final el in elements) {
      if (el is LinkableElement) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenUrl(el.url);
        _recognizers.add(recognizer);
        children.add(
          TextSpan(
            text: el.text,
            style: widget.linkStyle,
            recognizer: recognizer,
          ),
        );
      } else {
        children.addAll(_emojiAwareSpans(el.text, widget.baseStyle));
      }
    }
    return TextSpan(children: children);
  }

  @override
  Widget build(BuildContext context) => Text.rich(_span);
}

/// Conversation detail pane for a single room. Reads messages from
/// `messageStoreProvider(roomId)` and the signed-in username from
/// `accountProvider`. `onSend` is provided by the caller (inbox_shell) so
/// the integration session can plug the real WSS send path here without
/// re-touching the page.
class ConversationPage extends ConsumerStatefulWidget {
  const ConversationPage({
    super.key,
    required this.room,
    required this.selfUsername,
    required this.onSend,
    this.onRename,
    this.onRetry,
    this.onPickMedia,
    this.onSendMedia,
    this.onReact,
    this.onDelete,
    this.onEdit,
    this.onCancelSend,
    this.onTyping,
    this.onOpenAttachment,
    this.onSendVoice,
    this.focusMessageId,
  });

  final Room room;
  final String selfUsername;

  /// When set (opened from global search), scroll to and highlight this message
  /// once the conversation loads.
  final String? focusMessageId;
  final SendCallback onSend;
  final RenameCallback? onRename;
  final RetryCallback? onRetry;

  /// Tapped the composer's attach (+) button: pick media to stage on the
  /// composer (not send yet). Returns the picked items. Null disables the
  /// affordance.
  final Future<List<StagedAttachment>> Function()? onPickMedia;

  /// Send the staged media. The caption (composer text, may be empty) attaches
  /// to the last item so a multi-pick reads as one captioned run. [replyTo],
  /// when set, quotes an earlier message and attaches to the first item.
  final Future<void> Function(
    List<StagedAttachment> items,
    String caption,
    ReplyRef? replyTo,
  )?
  onSendMedia;

  /// React to a message (empty emoji = remove my reaction). Null disables the
  /// long-press bar, double-tap, and reaction pills.
  final ReactCallback? onReact;

  /// Unsend a confirmed message for everyone, by message id. Null hides the
  /// Delete action on confirmed messages.
  final void Function(String targetId)? onDelete;

  /// Edit a confirmed text message for everyone: (target id, new text). Null
  /// hides the Edit action. Only offered on my own confirmed text messages.
  final void Function(String targetId, String newText)? onEdit;

  /// Cancel an unconfirmed (still sending / failed) outgoing send, by its
  /// clientMsgId: drops the optimistic bubble and its outbox row. Null hides
  /// the Delete action on unconfirmed messages.
  final void Function(String clientMsgId)? onCancelSend;

  /// Relay my typing presence (true while composing, false when stopped). Null
  /// disables sending typing frames.
  final void Function(bool typing)? onTyping;

  /// Tapped a received/sent media tile to open it full-screen.
  final OpenAttachmentCallback? onOpenAttachment;

  /// Send a recorded voice memo (encrypt + upload + fan out as kind:"audio").
  /// Null disables the composer mic's record gesture. [replyTo], when set,
  /// quotes an earlier message.
  final Future<void> Function(VoiceRecording rec, ReplyRef? replyTo)?
  onSendVoice;

  String get roomId => room.roomId;

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage>
    with WidgetsBindingObserver {
  final _controller = _EmojiComposerController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();

  /// Message id to briefly highlight after a jump-to-message (from search).
  String? _highlightedId;

  /// Per-message keys so [Scrollable.ensureVisible] can land precisely on a
  /// jump target once its row is built. Created lazily as bubbles render.
  final Map<String, GlobalKey> _bubbleKeys = {};

  GlobalKey _bubbleKeyFor(String id) =>
      _bubbleKeys.putIfAbsent(id, GlobalKey.new);

  /// Saturation ×1.3 color matrix (luma-weighted rows). Composed over the
  /// composer's backdrop blur to mimic Apple's blur *material*: a plain
  /// gaussian blur goes muddy, so we lift saturation back up to keep the
  /// messages reading luminous through the glass.
  static const _glassSaturation = <double>[
    1.2361, -0.2145, -0.0216, 0, 0, //
    -0.0639, 1.0855, -0.0216, 0, 0, //
    -0.0639, -0.2145, 1.2784, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  /// Distance (in logical px) from the bottom that still counts as "at bottom".
  static const _stickThreshold = 120.0;
  bool _atBottom = true;
  int _prevMessageCount = 0;

  /// Message keys already on screen / already popped-in, so opening a room does
  /// not animate the whole history and the optimistic→server-id reconcile does
  /// not re-pop a sent message. Keyed off `clientMsgId ?? id` so the swap maps
  /// the reconciled row back to the entry the optimistic row already added.
  final Set<String> _animatedIds = {};
  bool _seededAnimics = false;

  /// Guards against stacking multiple post-frame scroll callbacks when a send
  /// triggers several rebuilds in quick succession (optimistic add → echo
  /// reconcile), which is what made the auto-scroll stutter.
  bool _scrollScheduled = false;

  /// Media picked but not yet sent, shown as a tray above the composer. Send
  /// flushes these (with the composer text as the last item's caption).
  final List<StagedAttachment> _staged = [];

  /// Drives the hold-to-record voice memo flow. A [ListenableBuilder] in the
  /// composer listens to this, so its frequent (timer + amplitude) ticks rebuild
  /// only the composer rather than the whole page. [_cancelArmed] tracks whether
  /// the current drag has crossed the slide-to-cancel threshold; [_startFuture]
  /// is the in-flight start() so a quick release can't race it.
  late final VoiceRecorderController _recorder = VoiceRecorderController(
    // Hitting the 5-minute cap sends the memo rather than dropping it.
    onMaxDuration: (rec) => _sendVoiceMemo(rec),
  );
  bool _cancelArmed = false;
  Future<bool>? _startFuture;

  /// The live long-press reaction/actions overlay, if one is showing. Tracked
  /// so it can be torn down in [dispose] — otherwise popping the page mid-
  /// display (back-swipe, room switch) leaves the entry mounted against a
  /// disposed state, with its animation controller still ticking.
  OverlayEntry? _reactionEntry;

  /// The id of the message currently being edited, or null in normal compose.
  /// While set, the composer shows the editing banner, the send button sends an
  /// edit (see [_handleSubmit]), and [_editingOriginal] is shown in the banner.
  String? _editingId;
  String _editingOriginal = '';

  /// The message being quoted by the next send, or null when not replying. Set
  /// by swipe-to-reply or the long-press "Reply" action; shown as a chip above
  /// the composer; attached to the next text/media/voice send then cleared.
  ReplyRef? _replyDraft;

  /// Direct replies keyed by the parent message id, recomputed each build from
  /// the store. Drives the "N replies" pill and the focused thread view.
  Map<String, List<Msg>> _replyChildren = const {};

  void _startReply(Msg m) {
    HapticFeedback.lightImpact();
    setState(() => _replyDraft = _replyRefFor(m));
    _composerFocus.requestFocus();
  }

  void _cancelReply() {
    if (_replyDraft == null) return;
    setState(() => _replyDraft = null);
  }

  /// Flush a recorded voice memo, attaching (and then clearing) any active
  /// reply draft. Shared by the mic gestures and the max-duration auto-send.
  Future<void> _sendVoiceMemo(VoiceRecording rec) async {
    final reply = _replyDraft;
    if (reply != null) setState(() => _replyDraft = null);
    await widget.onSendVoice?.call(rec, reply);
  }

  /// Build a [ReplyRef] snippet from a live message: kind from its attachment
  /// mime (image→photo, video→video, audio→voice, else file), or text; the
  /// excerpt is the body truncated to 140 chars for text messages.
  ReplyRef _replyRefFor(Msg m) {
    final att = m.attachment;
    final String kind;
    if (att == null) {
      kind = 'text';
    } else if (att.isVideo) {
      kind = 'video';
    } else if (att.isAudio) {
      kind = 'voice';
    } else if (att.mime.startsWith('image/')) {
      kind = 'photo';
    } else {
      kind = 'file';
    }
    // The body doubles as a media caption, so carry the excerpt for any kind
    // (a captioned photo quotes its caption; a bare photo quotes just "Photo").
    final body = m.body.trim();
    final excerpt = body.isEmpty
        ? null
        : (body.length > 140 ? body.substring(0, 140) : body);
    return ReplyRef(id: m.id, author: m.from, kind: kind, text: excerpt);
  }

  /// Whether the message can be quoted in a reply. Real timeline bubbles
  /// (text/media) are reply-able; call-log rows are not.
  bool _canReply(Msg m) => m.callOutcome == null;

  /// Whether [m] carries an image/video attachment that can be saved to Photos
  /// or shared (voice memos and text are excluded).
  bool _isSaveableMedia(Msg m) {
    final a = m.attachment;
    return a != null && (a.mime.startsWith('image/') || a.isVideo);
  }

  /// Decrypt the attachment to a local file (cached after the first fetch),
  /// then save it to the camera roll. Toasts on success/failure.
  Future<void> _saveAttachment(AttachmentDescriptor att) async {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    try {
      final file = await fetchAndDecrypt(conn: conn, descriptor: att);
      await saveToGallery(file, att);
      if (mounted) showLoveToast(context, 'Saved to Photos', icon: Icons.check);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
      }
    }
  }

  /// Decrypt the attachment to a local file, then hand it to the iOS share
  /// sheet.
  Future<void> _shareAttachment(AttachmentDescriptor att) async {
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) return;
    try {
      final file = await fetchAndDecrypt(conn: conn, descriptor: att);
      await shareFile(file, att);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
      }
    }
  }

  /// The live message with [id] from the current buffer, or null if it isn't
  /// loaded (scrolled out of history, or since unsent).
  Msg? _lookupMessage(String id) {
    for (final x in ref.read(messageStoreProvider(widget.roomId))) {
      if (x.id == id) return x;
    }
    return null;
  }

  /// Attribution label for a reply quote: "You" for my own message, else the
  /// author's username.
  String _replyAuthorLabel(String author) =>
      author == widget.selfUsername ? 'You' : author;

  /// One-line preview text for a quote: the excerpt for text, a kind label
  /// ("Photo" / "Voice message") for bare media, or "label · caption" when a
  /// captioned attachment is quoted.
  String _replyPreviewText(ReplyRef r) {
    final label = switch (r.kind) {
      'photo' => 'Photo',
      'video' => 'Video',
      'voice' => 'Voice message',
      'file' => 'File',
      _ => null,
    };
    final text = r.text?.trim();
    if (label == null) return text ?? '';
    return (text == null || text.isEmpty) ? label : '$label · $text';
  }

  /// Small leading glyph for a media quote (null for plain text).
  IconData? _replyKindIcon(String kind) => switch (kind) {
    'photo' => Icons.photo_outlined,
    'video' => Icons.videocam_outlined,
    'voice' => Icons.mic_none,
    'file' => Icons.insert_drive_file_outlined,
    _ => null,
  };

  /// iMessage-style reply quote: a shrunken, faded copy of the quoted message
  /// stacked above the reply (colored by the *original* sender) with a short
  /// connector linking the two. Resolves the live target when present (so it
  /// reflects later edits) and falls back to the cached [ReplyRef] snippet.
  /// Tapping the faded bubble jumps to the original.
  Widget _replyQuoteHeader(Msg m, bool mine) {
    final live = _lookupMessage(m.replyTo!.id);
    final r = live != null ? _replyRefFor(live) : m.replyTo!;
    final fromMe = r.author == widget.selfUsername;
    final bubbleColor = fromMe
        ? context.palette.bubbleUserBg
        : context.palette.bubblePartnerBg;
    final icon = _replyKindIcon(r.kind);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // The quoted message, shrunk + faded, pulled to the reply's side.
          Padding(
            padding: EdgeInsets.only(left: mine ? 0 : 22, right: mine ? 22 : 0),
            child: Opacity(
              opacity: 0.55,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _focusMessage(r.id),
                child: Container(
                  key: Key('reply-quote-${m.id}'),
                  constraints: const BoxConstraints(maxWidth: 240),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 14, color: context.palette.textMuted),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          _replyPreviewText(r),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.palette.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Short connector from the quoted bubble down to the reply.
          Padding(
            padding: EdgeInsets.only(left: mine ? 0 : 14, right: mine ? 14 : 0),
            child: Container(
              width: 2.5,
              height: 9,
              decoration: BoxDecoration(
                color: context.palette.textMuted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Whether we've sent `typing:true` and not yet sent the matching `false`.
  bool _typingActive = false;
  Timer? _typingStop;
  Timer? _typingHeartbeat;

  /// How long after the last keystroke we declare typing stopped.
  static const _typingStopDelay = Duration(seconds: 4);

  /// How often we re-assert `typing:true` while composing. Must stay under the
  /// receiver's safety timeout (see [TypingNotifier]) so the partner's bubble
  /// never expires mid-typing, and so a dropped frame / reconnect self-heals.
  static const _typingHeartbeatInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
      // This chat is now on screen: it owns the read-receipt signal, and
      // opening it marks everything read. Done post-frame to avoid mutating a
      // provider during the first build. We capture the controller here because
      // `ref` is unusable in dispose (the element is already gone by then).
      if (!mounted) return;
      _activeRoom = ref.read(activeRoomProvider.notifier);
      _activeRoom!.state = widget.roomId;
      markRoomRead(ref, widget.roomId);
      // Opened from global search: jump to + highlight the target message.
      final focusId = widget.focusMessageId;
      if (focusId != null) _focusMessage(focusId);
    });
  }

  /// The active-room controller, captured on mount so [dispose] can clear it
  /// without touching the (by-then disposed) [ref].
  StateController<String?>? _activeRoom;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding drops the socket and freezes timers; clear typing so a
    // stale `_typingActive` flag can't suppress the next `true` on resume. An
    // in-progress edit is transient — drop it too, so resuming starts fresh.
    if (state != AppLifecycleState.resumed) {
      _stopTyping();
      if (_editingId != null) _cancelEdit();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final atBottom = pos.pixels < _stickThreshold;
    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
  }

  /// Scroll to [messageId] (from a search result) and pulse a highlight on it.
  /// Hydrates the full room history from the local store first if the target
  /// predates what's loaded in memory. In the lazy reverse list the row may not
  /// be built yet, so jump toward its proportional offset until its element
  /// exists, then [Scrollable.ensureVisible] aligns it precisely.
  Future<void> _focusMessage(String messageId) async {
    final store = ref.read(messageStoreProvider(widget.roomId).notifier);
    bool present() => ref
        .read(messageStoreProvider(widget.roomId))
        .any((m) => m.id == messageId);
    if (!present()) {
      final db = await ref.read(messageDbProvider.future);
      store.setAll(await db.messagesFor(widget.roomId));
      await WidgetsBinding.instance.endOfFrame;
      if (!present()) return; // not in full history (e.g. since unsent)
    }
    if (!mounted) return;
    setState(() => _highlightedId = messageId);

    // The message set is stable during the focus op, so compute the target's
    // index in the reversed list once (not per retry frame).
    final sorted = [...ref.read(messageStoreProvider(widget.roomId))]
      ..sort((a, b) => a.ts.compareTo(b.ts));
    final items = _itemize(sorted).reversed.toList();
    final idx = items.indexWhere(
      (it) => it is _BubbleItem && it.msg.id == messageId,
    );

    for (var attempt = 0; attempt < 12; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) return;
      final ctx = _bubbleKeys[messageId]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 300),
        );
        break;
      }
      if (idx < 0) break;
      // Target not built yet: jump toward its index's proportional offset to
      // bring its region into the build window, then retry on the next frame.
      final pos = _scrollController.position;
      final frac = items.length <= 1 ? 0.0 : idx / (items.length - 1);
      _scrollController.jumpTo(
        (pos.maxScrollExtent * frac).clamp(0.0, pos.maxScrollExtent),
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _highlightedId = null);
  }

  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Stick to the newest message after a rebuild adds one. Coalesced to a
  /// single post-frame callback. When already pinned to the bottom, the
  /// reverse list reveals the new bubble on its own — replaying an animation
  /// over it is exactly what felt choppy — so only animate when we were
  /// genuinely scrolled away from the bottom.
  void _scheduleStickToBottom() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!_scrollController.hasClients) return;
      if (_scrollController.position.pixels <= 4) return;
      _animateToBottom();
    });
  }

  @override
  void dispose() {
    // Leaving the chat: drop the read-receipt signal. Riverpod forbids
    // mutating a provider inside dispose, so defer to a microtask. Clear only
    // if it still points at us — a faster push of another room may have claimed
    // it by the time this runs.
    final activeRoom = _activeRoom;
    final roomId = widget.roomId;
    if (activeRoom != null) {
      Future.microtask(() {
        if (activeRoom.state == roomId) activeRoom.state = null;
      });
    }
    _dismissReactionBar();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _controller.dispose();
    _composerFocus.dispose();
    _recorder.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _typingStop?.cancel();
    _typingHeartbeat?.cancel();
    // Leaving the room while composing: tell the partner we stopped.
    if (_typingActive) widget.onTyping?.call(false);
    super.dispose();
  }

  void _handleSubmit(String value) {
    final text = value.trim();
    // Staged media takes the composer text as a caption (on the last item) and
    // flushes through onSendMedia. An empty caption is fine — just send the
    // media. Text-only sends fall through to onSend below.
    if (_staged.isNotEmpty) {
      HapticFeedback.lightImpact();
      final items = List<StagedAttachment>.of(_staged);
      widget.onSendMedia?.call(items, text, _replyDraft);
      ref.read(wallpaperDriftProvider.notifier).bump();
      setState(() {
        _staged.clear();
        _replyDraft = null;
      });
      _controller.clear();
      _stopTyping();
      return;
    }
    // In edit mode the send button commits an edit instead of a new message.
    // An empty edit is a no-op cancel (never a delete); an unchanged edit just
    // exits edit mode without sending a redundant frame.
    final editingId = _editingId;
    if (editingId != null) {
      if (text.isNotEmpty && text != _editingOriginal.trim()) {
        HapticFeedback.lightImpact();
        widget.onEdit?.call(editingId, text);
        ref.read(wallpaperDriftProvider.notifier).bump();
      }
      _cancelEdit();
      _stopTyping();
      return;
    }
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.onSend(text, _replyDraft);
    ref.read(wallpaperDriftProvider.notifier).bump();
    if (_replyDraft != null) setState(() => _replyDraft = null);
    _controller.clear();
    _stopTyping();
  }

  /// Enter edit mode for [m]: prefill the composer with its text (cursor at the
  /// end) and raise the editing banner. The send button now commits the edit.
  void _enterEditMode(Msg m) {
    setState(() {
      _editingId = m.id;
      _editingOriginal = m.body;
    });
    _controller.text = m.body;
    _controller.selection = TextSelection.collapsed(offset: m.body.length);
    _composerFocus.requestFocus();
  }

  /// Leave edit mode and clear the composer. Transient: also triggered by
  /// backgrounding the app (see [didChangeAppLifecycleState]).
  void _cancelEdit() {
    if (_editingId == null) return;
    setState(() {
      _editingId = null;
      _editingOriginal = '';
    });
    _controller.clear();
  }

  /// Debounced typing presence: the first keystroke after idle emits
  /// `typing:true`; each subsequent keystroke pushes back a stop timer that
  /// emits `typing:false` once composing pauses (or the field empties).
  void _onComposerChanged(String value) {
    if (widget.onTyping == null) return;
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (!_typingActive) {
      _typingActive = true;
      widget.onTyping!(true);
      // Re-assert `true` on a heartbeat so the partner's bubble doesn't expire
      // while we keep typing, and so a dropped frame / reconnect re-syncs.
      _typingHeartbeat = Timer.periodic(_typingHeartbeatInterval, (_) {
        if (_typingActive) widget.onTyping?.call(true);
      });
    }
    _typingStop?.cancel();
    _typingStop = Timer(_typingStopDelay, _stopTyping);
  }

  void _stopTyping() {
    _typingStop?.cancel();
    _typingHeartbeat?.cancel();
    _typingHeartbeat = null;
    if (_typingActive) {
      _typingActive = false;
      widget.onTyping?.call(false);
    }
  }

  Future<void> _pickMedia() async {
    final picked = await widget.onPickMedia?.call();
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _staged.addAll(picked));
  }

  void _removeStaged(int index) {
    setState(() => _staged.removeAt(index));
  }

  /// Toggle/replace my reaction on [m]: tapping the one I already picked clears
  /// it; any other emoji replaces it (each person has at most one reaction,
  /// Telegram style).
  void _react(Msg m, String emoji) {
    final mine = m.reactions[widget.selfUsername];
    widget.onReact?.call(m.id, mine == emoji ? '' : emoji);
  }

  /// A message carries copyable text when its body is non-empty (plain text,
  /// or a media caption).
  bool _canCopy(Msg m) => m.body.trim().isNotEmpty;

  /// The Delete action for [m], or null if it can't be deleted. Two behaviors,
  /// both only on my own messages, keyed on send state (not clientMsgId, which
  /// a reconciled row now retains for stable list keys):
  ///  - confirmed (sent/read, so a server id both sides know): unsend for
  ///    everyone via [onDelete];
  ///  - still in-flight or failed (no shared server id): cancel the send
  ///    locally via [onCancelSend] — discards the bubble and drops the outbox
  ///    row. This is what clears a stuck "sending" bubble.
  VoidCallback? _deleteAction(Msg m, bool mine) {
    if (!mine) return null;
    switch (m.sendStatus) {
      case SendStatus.sent:
      case SendStatus.read:
        return widget.onDelete == null ? null : () => widget.onDelete!(m.id);
      case SendStatus.sending:
      case SendStatus.failed:
        final cid = m.clientMsgId;
        return (widget.onCancelSend == null || cid == null)
            ? null
            : () => widget.onCancelSend!(cid);
    }
  }

  void _copy(Msg m) {
    Clipboard.setData(ClipboardData(text: m.body));
    if (!mounted) return;
    showLoveToast(context, 'Copied', icon: Icons.check);
  }

  /// The Edit action for [m], or null if it can't be edited. Only my own
  /// confirmed (sent/read, so a shared server id) *text* messages are editable —
  /// not media/voice/call rows, and not still-sending ones (nothing remote to
  /// edit yet; cancel + retype instead, like [_deleteAction]).
  VoidCallback? _editAction(Msg m, bool mine) {
    if (!mine || widget.onEdit == null) return null;
    if (m.attachment != null || m.callOutcome != null) return null;
    switch (m.sendStatus) {
      case SendStatus.sent:
      case SendStatus.read:
        return () => _enterEditMode(m);
      case SendStatus.sending:
      case SendStatus.failed:
        return null;
    }
  }

  /// Long-press a bubble → floating context menu anchored at the press: a
  /// quick-reaction bar (when reactions are enabled) plus Copy/Delete actions.
  void _showReactionBar(Offset globalPos, Msg m) {
    final mine = m.from == widget.selfUsername;
    final canCopy = _canCopy(m);
    final canReply = _canReply(m);
    final isMedia = _isSaveableMedia(m);
    final edit = _editAction(m, mine);
    final delete = _deleteAction(m, mine);
    if (widget.onReact == null &&
        !canReply &&
        !canCopy &&
        !isMedia &&
        edit == null &&
        delete == null) {
      return;
    }
    HapticFeedback.mediumImpact();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => _ReactionBarOverlay(
        anchor: globalPos,
        selected: m.reactions[widget.selfUsername],
        showReactions: widget.onReact != null,
        onPick: (emoji) {
          _dismissReactionBar();
          _react(m, emoji);
        },
        onMore: () {
          _dismissReactionBar();
          _openReactionPicker(m);
        },
        onReply: canReply
            ? () {
                _dismissReactionBar();
                _startReply(m);
              }
            : null,
        onCopy: canCopy
            ? () {
                _dismissReactionBar();
                _copy(m);
              }
            : null,
        onEdit: edit == null
            ? null
            : () {
                _dismissReactionBar();
                edit();
              },
        onSaveMedia: isMedia
            ? () {
                _dismissReactionBar();
                _saveAttachment(m.attachment!);
              }
            : null,
        onShareMedia: isMedia
            ? () {
                _dismissReactionBar();
                _shareAttachment(m.attachment!);
              }
            : null,
        onDelete: delete == null
            ? null
            : () {
                _dismissReactionBar();
                delete();
              },
        onDismiss: _dismissReactionBar,
      ),
    );
    _reactionEntry = entry;
    overlay.insert(entry);
  }

  /// Tear down the long-press overlay if one is up. Safe to call repeatedly and
  /// from [dispose].
  void _dismissReactionBar() {
    _reactionEntry?.remove();
    _reactionEntry = null;
  }

  Future<void> _openReactionPicker(Msg m) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.bgSurface,
      builder: (ctx) => SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.pop(ctx);
            _react(m, emoji.emoji);
          },
          config: Config(
            height: 320,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: context.palette.bgSurface,
              columns: 7,
              emojiSizeMax: 32,
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: context.palette.bgSurface,
              indicatorColor: context.palette.accentUser,
              iconColor: context.palette.textMuted,
              iconColorSelected: context.palette.accentUser,
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: context.palette.bgSurface,
              buttonColor: context.palette.bgSurfaceAlt,
              buttonIconColor: context.palette.accentUser,
            ),
            searchViewConfig: SearchViewConfig(
              backgroundColor: context.palette.bgSurface,
              buttonIconColor: context.palette.accentUser,
            ),
          ),
        ),
      ),
    );
  }

  void _submitFromIntent() {
    _handleSubmit(_controller.text);
  }

  /// Stable identity string for a list row, used for both its [ValueKey] and
  /// [SliverChildBuilderDelegate.findChildIndexCallback]. The latter is what
  /// lets the builder relocate an existing keyed element when a new message
  /// shifts every index — without it the delegate rebuilds the visible
  /// children on each insert (the whole list flashes on receive).
  static String _rowKey(_Item item) => switch (item) {
    _BubbleItem(:final msg) => 'msg-${msg.clientMsgId ?? msg.id}',
    _DayItem(:final day) => 'day-${day.toIso8601String()}',
    _GapItem(:final time) => 'gap-${time.toIso8601String()}',
  };

  /// The partner's username — the room's one other member — or null for a solo
  /// room (no partner yet). Drives the presence line in the title pill.
  String? _partnerUsername() {
    for (final m in widget.room.members) {
      if (m.username != widget.selfUsername) return m.username;
    }
    return null;
  }

  Color _senderColor(String username) {
    if (username == widget.selfUsername) return context.palette.accentUser;
    // Stable hash → one of three accents per spec §7.5 (sage / mauve / wine).
    const palette = <Color>[
      Color(0xFF4F7A5E), // sage
      Color(0xFF9C7E94), // mauve
      Color(0xFF8A3E5A), // wine
    ];
    var h = 0;
    for (final c in username.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messageStoreProvider(widget.roomId));
    final me = ref.watch(accountProvider).valueOrNull?.username ?? '';

    // Seed the pop-in set once the store first has messages, so the existing
    // history renders without animating. Crucially we wait for a *non-empty*
    // build: the store hydrates from the local DB asynchronously (see
    // RoomMessageRouter._subscribe → setAll), which routinely lands *after* this
    // page's first build. Seeding on an empty first build would mark nothing,
    // then pop the entire history in when it hydrates. A brand-new empty room
    // stays unseeded until its first real message, which then correctly pops.
    if (!_seededAnimics && messages.isNotEmpty) {
      for (final m in messages) {
        _animatedIds.add(m.clientMsgId ?? m.id);
      }
      _seededAnimics = true;
    }

    // Partner profile drives the header name + avatar (and the room list).
    final profiles = ref.watch(profileStoreProvider);
    String? nameFor(String u) => profiles.forUsername(u)?.displayName;
    final partner = _partnerUsername();
    final partnerProfile = partner != null
        ? profiles.forUsername(partner)
        : null;
    final partnerAvatar = partner != null
        ? profiles.avatarFileFor(partner)
        : null;
    final partnerSeed = (partnerProfile?.displayName?.isNotEmpty ?? false)
        ? partnerProfile!.displayName!
        : (partner ?? widget.room.displayName(widget.selfUsername));

    // The reverse list keeps the newest message pinned on its own whenever
    // we're already at the bottom, so the only case that needs a programmatic
    // scroll is sending a message while scrolled away from the bottom (jump
    // down to it). Forcing a scroll while already at the bottom is what caused
    // the pull-up-then-jump-down on send — the post-send composer reflow makes
    // the position read as briefly off, triggering a needless animate.
    if (messages.length > _prevMessageCount) {
      final newest = messages.fold<Msg?>(
        null,
        (acc, m) => acc == null || m.ts.isAfter(acc.ts) ? m : acc,
      );
      final mine = newest?.from == me;
      if (mine && !_atBottom) {
        _scheduleStickToBottom();
      }
    }
    _prevMessageCount = messages.length;

    final sorted = [...messages]..sort((a, b) => a.ts.compareTo(b.ts));
    // Index direct replies by parent id for the "N replies" pill + thread view.
    final replyChildren = <String, List<Msg>>{};
    for (final m in sorted) {
      final parent = m.replyTo?.id;
      if (parent != null) {
        (replyChildren[parent] ??= <Msg>[]).add(m);
      }
    }
    _replyChildren = replyChildren;
    final status = _statusModel(sorted, me);
    // Reversed, so index 0 is the visual bottom — i.e. the newest message is
    // the true leading edge, which is what lets a reverse list pin to the
    // bottom on its own. The partner's "typing…" indicator deliberately lives
    // in the app bar (not as a bottom row) so it never reflows this list.
    final items = _itemize(sorted).reversed.toList();
    // Keyboard height. We keep the wallpaper full-bleed behind the keyboard
    // (Telegram-style) by turning off Scaffold's auto-resize and instead
    // lifting the composer + the list's reserved bottom by this inset
    // ourselves — otherwise the resized body leaves a black band where the
    // transparent scaffold shows through as the keyboard slides.
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    // Unread waiting in the user's *other* threads — badged on the back button
    // so partner activity elsewhere isn't invisible while you're in this chat.
    final unreadElsewhere = ref.watch(
      unreadElsewhereCountProvider((
        me: widget.selfUsername,
        roomId: widget.room.roomId,
      )),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        // White status-bar icons — they sit over the dark top scrim (painted
        // in the body so it's taller/stronger than an app-bar-only gradient).
        systemOverlayStyle: SystemUiOverlayStyle.light,
        // Back arrow in a pill, matching the ⋯ menu, when this chat was pushed
        // onto a route (home → chat). Null in tests that mount it directly.
        leading: Navigator.of(context).canPop()
            ? IconButton(
                key: const Key('room-back-button'),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: context.palette.bgSurface.withValues(alpha: 0.7),
                      ),
                      child: Icon(
                        Icons.arrow_back_ios_new,
                        color: context.palette.textPrimary,
                        size: 18,
                      ),
                    ),
                    if (unreadElsewhere > 0)
                      Positioned(
                        top: -3,
                        right: -3,
                        child: _unreadBadge(unreadElsewhere),
                      ),
                  ],
                ),
              )
            : null,
        centerTitle: true,
        // The room name as a centered pill; tapping it opens the chat-info
        // page (Telegram-style: call/video/search + media/voice/links).
        title: GestureDetector(
          key: const Key('room-title-pill'),
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final focusId = await Navigator.of(context).push(
              ChatInfoPage.route(
                room: widget.room,
                selfUsername: widget.selfUsername,
                onRename: widget.onRename,
              ),
            );
            if (focusId != null) await _focusMessage(focusId);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            decoration: BoxDecoration(
              color: context.palette.bgSurface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.room.displayName(
                    widget.selfUsername,
                    nameFor: nameFor,
                  ),
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    color: context.palette.textPrimary,
                  ),
                ),
                _PartnerStatusLine(
                  roomId: widget.roomId,
                  partner: _partnerUsername(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          // One explicit row of equal 34px slots with equal gaps, so the video
          // button, the call button and the avatar are evenly spaced (laying them
          // out as separate AppBar actions left the IconButton sizing uneven).
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    key: const Key('video-call-button'),
                    padding: EdgeInsets.zero,
                    icon: _headerCircleIcon(context, Icons.videocam),
                    onPressed: () {
                      ref
                          .read(callControllerProvider)
                          .placeCall(widget.roomId, video: true);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    key: const Key('call-button'),
                    padding: EdgeInsets.zero,
                    icon: _headerCircleIcon(context, Icons.call),
                    onPressed: () {
                      // The CallOverlay shows the in-app call UI automatically
                      // once the call is dialing.
                      ref.read(callControllerProvider).placeCall(widget.roomId);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  key: const Key('room-header-avatar'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final focusId = await Navigator.of(context).push(
                      ChatInfoPage.route(
                        room: widget.room,
                        selfUsername: widget.selfUsername,
                        onRename: widget.onRename,
                      ),
                    );
                    if (focusId != null) await _focusMessage(focusId);
                  },
                  child: Avatar(
                    seedText: partnerSeed,
                    imageFile: partnerAvatar,
                    radius: 17,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: WallpaperBackground(
        // Column push-down: the message list lives in an Expanded above the
        // composer, so when the composer grows a line Flutter shrinks the list
        // in the *same* layout pass — messages push up instantly instead of
        // being briefly covered by the bar (the old floating-Stack + measured-
        // padding approach lagged the growth by a frame). The composer keeps
        // its bottom:keyboardInset padding to ride above the keyboard, so the
        // Expanded list sizes around composer + keyboard naturally (auto-resize
        // stays off — see keyboardInset above).
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    // Tap the chat to dismiss the keyboard (Telegram-style). A
                    // real onTap — not a TapRegion — only fires on a tap that
                    // isn't a drag: the list's vertical-drag recognizer wins the
                    // gesture arena during a scroll, so scrolling up keeps the
                    // keyboard up. Opaque so taps land on the wallpaper gutters
                    // and empty space too, not just on message bubbles.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      child: ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: EdgeInsets.only(
                          left: 16,
                          right: 16,
                          top:
                              4 +
                              MediaQuery.of(context).padding.top +
                              kToolbarHeight,
                          bottom: 12,
                        ),
                        itemCount: items.length,
                        // Relocate existing keyed rows by identity when an
                        // insert shifts indices, so the delegate reuses them
                        // instead of rebuilding the visible list (the
                        // receive-time flash).
                        findChildIndexCallback: (key) {
                          final value = (key as ValueKey<String>).value;
                          final idx = items.indexWhere(
                            (it) => _rowKey(it) == value,
                          );
                          return idx < 0 ? null : idx;
                        },
                        itemBuilder: (_, i) {
                          final item = items[i];
                          final child = switch (item) {
                            _BubbleItem(:final msg) => _bubbleRow(
                              msg,
                              me,
                              status.inBubble[msg.id],
                              status.failedRun[msg.id],
                            ),
                            _DayItem(:final day) => _daySeparator(day),
                            _GapItem(:final time) => _gapHeader(time),
                          };
                          return KeyedSubtree(
                            key: ValueKey(_rowKey(item)),
                            child: child,
                          );
                        },
                      ),
                    ),
                  ),
                  // Frosted, darkened scrim behind the status bar + app-bar
                  // pills so the OS clock/battery and the title stay legible
                  // over the wallpaper, Telegram-style. Messages scroll under
                  // it and blur.
                  _topScrim(context),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: _atBottom ? 0 : 1,
                      child: IgnorePointer(
                        ignoring: _atBottom,
                        child: FloatingActionButton.small(
                          key: const Key('jump-to-bottom'),
                          backgroundColor: context.palette.bgSurface,
                          foregroundColor: context.palette.accentUser,
                          elevation: 4,
                          onPressed: _animateToBottom,
                          tooltip: 'Jump to latest',
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: _composer(),
            ),
          ],
        ),
      ),
    );
  }

  /// Small red count badge for the back button — unread waiting in other
  /// threads. iOS system red, white count, capped at "9+".
  static Widget _unreadBadge(int count) {
    final label = count > 9 ? '9+' : '$count';
    return Container(
      key: const Key('back-unread-badge'),
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: const BoxDecoration(
        color: Color(0xFFFF3B30),
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontSize: 10,
          height: 1.0,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// Wraps [_bubble] for the message list, popping in rows that arrived after
  /// the room opened (sent and received). [Set.add] returns true only the first
  /// time a key is seen; seeded history and reconciled rows are already present,
  /// so they render without the animation.
  Widget _bubbleRow(
    Msg m,
    String me,
    _Marker? marker,
    List<String>? failedIds,
  ) {
    final bubble = _bubble(m, me, marker, failedIds);
    final animKey = m.clientMsgId ?? m.id;
    final firstAppearance = _animatedIds.add(animKey);
    if (!firstAppearance) return bubble;
    return _PopIn(
      key: Key('popin-${m.id}'),
      alignEnd: m.from == me,
      child: bubble,
    );
  }

  Widget _bubble(Msg m, String me, _Marker? marker, List<String>? failedIds) {
    final mine = m.from == me;
    // The sent/sending marker (if any) is drawn inside the bubble itself.
    Widget content = _bubbleContent(m, me, marker);
    // A reply quotes its target above the bubble, side-aligned to match.
    if (m.replyTo != null) {
      content = Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [_replyQuoteHeader(m, mine), content],
      );
    }
    // Long-press → context menu (reactions + Copy/Delete); double-tap →
    // default reaction. Wraps both text and media bubbles; the media bubble's
    // own tap-to-open still wins for a plain tap (deferToChild).
    final canLongPress =
        widget.onReact != null ||
        _canReply(m) ||
        _canCopy(m) ||
        _editAction(m, mine) != null ||
        _deleteAction(m, mine) != null;
    if (canLongPress) {
      content = GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onLongPressStart: (d) => _showReactionBar(d.globalPosition, m),
        onDoubleTap: widget.onReact != null
            ? () => _react(m, _quickReactions.first)
            : null,
        child: content,
      );
    }

    // A failed run collapses a "tap to retry" caption under the trailing
    // bubble; tapping it retries every failed message in the run.
    Widget result;
    if (failedIds == null) {
      result = content;
    } else {
      final tappable = widget.onRetry != null
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                for (final id in failedIds) {
                  widget.onRetry!(id);
                }
              },
              child: content,
            )
          : content;
      result = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          tappable,
          Padding(
            padding: const EdgeInsets.only(right: 16, top: 2, bottom: 2),
            child: Text(
              'failed · tap to retry',
              style: TextStyle(
                color: context.palette.warningTone,
                fontSize: 11,
              ),
            ),
          ),
        ],
      );
    }

    final replyKids = _replyChildren[m.id];
    final hasReplies = replyKids != null && replyKids.isNotEmpty;
    final extras = <Widget>[
      if (m.reactions.isNotEmpty) _reactionPills(m, me, mine),
      if (hasReplies) _repliesPill(m, replyKids.length, mine),
    ];
    final Widget bubble = extras.isEmpty
        ? result
        : Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [result, ...extras],
          );

    // Keyed so a jump-to-message (search) can ensureVisible it; pulses a tint
    // while it's the highlighted target.
    final highlighted = m.id == _highlightedId;
    final container = AnimatedContainer(
      key: _bubbleKeyFor(m.id),
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: highlighted
            ? context.palette.accentUser.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: bubble,
    );
    // Swipe a real bubble toward center (own → left, partner's → right) to
    // reply; call-log rows aren't reply-able.
    if (!_canReply(m)) return container;
    return _SwipeToReply(
      mine: mine,
      onReply: () => _startReply(m),
      child: container,
    );
  }

  /// Aggregated reaction pills under a bubble (emoji → count). Mine is
  /// highlighted; tapping a pill toggles my reaction to that emoji. Pills hug
  /// the message side (flush with the bubble's edge) rather than sitting inset.
  Widget _reactionPills(Msg m, String me, bool mine) {
    final counts = <String, int>{};
    for (final e in m.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mineEmoji = m.reactions[me];
    return Padding(
      padding: mine
          ? const EdgeInsets.only(left: 8, right: 2, top: 2, bottom: 2)
          : const EdgeInsets.only(left: 2, right: 8, top: 2, bottom: 2),
      child: Wrap(
        spacing: 4,
        children: [
          for (final entry in counts.entries)
            _ReactionPill(
              emoji: entry.key,
              count: entry.value,
              mine: entry.key == mineEmoji,
              onTap: () => _react(m, entry.key),
            ),
        ],
      ),
    );
  }

  /// "N replies" affordance under a message that has replies (iMessage-style).
  /// Tapping opens the focused thread view rooted at [root].
  Widget _repliesPill(Msg root, int count, bool mine) {
    final accent = context.palette.accentSage;
    return Padding(
      padding: mine
          ? const EdgeInsets.only(right: 12, top: 1, bottom: 2)
          : const EdgeInsets.only(left: 12, top: 1, bottom: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openThread(root),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 13, color: accent),
            const SizedBox(width: 4),
            Text(
              count == 1 ? '1 reply' : '$count replies',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Open the focused thread view: blur the chat behind and show just this
  /// thread (root + replies) with a composer that replies back into it.
  void _openThread(Msg root) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.2),
        barrierDismissible: true,
        pageBuilder: (_, _, _) => _ThreadFocusView(
          roomId: widget.roomId,
          rootId: root.id,
          me: widget.selfUsername,
          onSend: (text) => widget.onSend(text, _replyRefFor(root)),
        ),
      ),
    );
  }

  /// Heart (sent) or clock (sending) tucked into a bubble's bottom-right
  /// corner, Telegram style.
  static Widget _markerWidget(_Marker marker, AppPalette palette) {
    return switch (marker) {
      _Marker.sent => _heart(palette.accentUser, key: 'status-heart'),
      // Read = a double heart: a soft trailing heart with the full-accent heart
      // overlapping on top. Both tones come from theme tokens (not baked into
      // the asset) so a future palette switcher recolors them together.
      _Marker.read => SizedBox(
        key: const Key('status-double-heart'),
        height: 11,
        width: 18,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, child: _heart(palette.accentUserSoft)),
            Positioned(left: 6, child: _heart(palette.accentUser)),
          ],
        ),
      ),
      _Marker.sending => Icon(
        Icons.schedule,
        key: const Key('status-clock'),
        size: 12,
        color: palette.textMuted,
      ),
    };
  }

  static Widget _heart(Color color, {String? key}) => SvgPicture.asset(
    'assets/icons/heart-sent.svg',
    key: key == null ? null : Key(key),
    height: 11,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );

  Widget _bubbleContent(Msg m, String me, _Marker? marker) {
    final mine = m.from == me;
    // A call-log entry: a side-aligned pill (outgoing → right, incoming → left,
    // Telegram-style) keeping our phone glyphs. Missed/declined show red.
    if (m.callOutcome != null) {
      final missed = m.callOutcome == 'missed' || m.callOutcome == 'declined';
      final accent = missed
          ? const Color(0xFFC0455B)
          : context.palette.accentSage;
      // The call type is carried by the body's leading glyph (📹 video / 📞
      // audio), set in call_log.dart. Use our own branded SVG for each.
      final isVideo = m.body.startsWith('📹');
      final icon = isVideo
          ? 'assets/icons/call-video.svg'
          : 'assets/icons/call-audio.svg';
      final label = m.body.replaceFirst(RegExp(r'^(📞|📹)\s*'), '');
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: context.palette.bgSurface.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset(
                icon,
                height: 15,
                colorFilter: ColorFilter.mode(accent, BlendMode.srcIn),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: missed ? accent : context.palette.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (m.attachment != null) {
      final att = m.attachment!;
      // Voice memos read as a chat bubble (same background + tail as text),
      // with the player inside; images keep their edge-to-edge media tile.
      if (att.isAudio) return _audioBubble(m, mine, marker, att);
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: _MediaBubble(
            msg: m,
            isMe: mine,
            marker: marker,
            onOpen: () => widget.onOpenAttachment?.call(att),
          ),
        ),
      );
    }
    // Cap the bubble so there's always a gutter on the opposite side, like
    // iMessage/Telegram. A fixed 480 never bites on a phone, so fall back to a
    // fraction of the viewport; the 480 ceiling keeps desktop bubbles sane.
    final viewportFraction = MediaQuery.sizeOf(context).width * 0.78;
    final maxBubbleWidth = viewportFraction < 480 ? viewportFraction : 480.0;
    final showSenderLabel = !mine && widget.room.members.length >= 3;
    // iMessage-style "jumbomoji": a message of just 1–3 emoji renders large and
    // bubble-less, with a single emoji biggest and shrinking toward three. 4+
    // emoji fall through to a normal text bubble. Sizes are starting points to
    // tune on-device against iMessage.
    final emojiCount = _emojiOnlyCount(m.body);
    if (emojiCount >= 1 && emojiCount <= 3) {
      final emojiSize = switch (emojiCount) {
        1 => 64.0,
        2 => 52.0,
        _ => 44.0,
      };
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
          child: Text(
            m.body.trim(),
            style: TextStyle(fontSize: emojiSize, height: 1.1),
          ),
        ),
      );
    }
    final bubbleColor = mine
        ? context.palette.bubbleUserBg
        : context.palette.bubblePartnerBg;
    final bubbleBorder = context.palette.borderSoft;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showSenderLabel)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 4),
              child: Text(
                m.from,
                key: Key('sender-label-${m.id}'),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  letterSpacing: 1.0,
                  color: _senderColor(m.from),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: CustomPaint(
              key: Key('bubble-bg-${m.clientMsgId ?? m.id}'),
              painter: _BubbleBackground(
                color: bubbleColor,
                border: bubbleBorder,
                mine: mine,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: _bubbleBody(m, mine, marker),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A voice memo rendered inside a chat bubble — same [_BubbleBackground]
  /// (colour + tail + border) as a text message, with the audio player on top
  /// and the hh:mm timestamp + status marker tucked bottom-right.
  Widget _audioBubble(
    Msg m,
    bool mine,
    _Marker? marker,
    AttachmentDescriptor att,
  ) {
    final showSenderLabel = !mine && widget.room.members.length >= 3;
    final bubbleColor = mine
        ? context.palette.bubbleUserBg
        : context.palette.bubblePartnerBg;
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatHm(m.ts.toLocal()),
          style: TextStyle(
            fontSize: 10,
            color: mine
                ? context.palette.bubbleUserText.withValues(alpha: 0.55)
                : context.palette.textMuted,
          ),
        ),
        if (marker != null) ...[
          const SizedBox(width: 4),
          _markerWidget(marker, context.palette),
        ],
      ],
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showSenderLabel)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 4),
              child: Text(
                m.from,
                key: Key('sender-label-${m.id}'),
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  letterSpacing: 1.0,
                  color: _senderColor(m.from),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: CustomPaint(
              key: Key('bubble-bg-${m.clientMsgId ?? m.id}'),
              painter: _BubbleBackground(
                color: bubbleColor,
                border: context.palette.borderSoft,
                mine: mine,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 10, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AudioBubble(
                      descriptor: att,
                      isMe: mine,
                      controller: ref.read(voicePlaybackControllerProvider),
                      conn: ref.read(liveConnectionProvider).asData?.value,
                    ),
                    meta,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _bubbleBody(Msg m, bool mine, _Marker? marker) {
    final textColor = mine
        ? context.palette.bubbleUserText
        : context.palette.textPrimary;
    final text = _MessageBody(
      body: m.body,
      baseStyle: TextStyle(color: textColor, fontSize: _bodyFontSize),
      linkStyle: TextStyle(
        color: textColor,
        fontSize: _bodyFontSize,
        decoration: TextDecoration.underline,
        decorationColor: textColor.withValues(alpha: 0.6),
      ),
      onOpenUrl: _openUrl,
    );
    // Every bubble carries an hh:mm timestamp bottom-right; my bubbles add the
    // sent/sending marker just to the right of the time. An edited message gets
    // a quiet "edited" tag just before the time (both sides see it).
    final metaColor = mine
        ? context.palette.bubbleUserText.withValues(alpha: 0.55)
        : context.palette.textMuted;
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.edited) ...[
          Text(
            'edited',
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: metaColor,
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          _formatHm(m.ts.toLocal()),
          style: TextStyle(fontSize: 10, color: metaColor),
        ),
        if (marker != null) ...[
          const SizedBox(width: 4),
          _markerWidget(marker, context.palette),
        ],
      ],
    );

    final preview = m.linkPreview;
    if (preview != null && preview.hasContent) {
      // Text, then the link-preview card, then the meta tucked bottom-right.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.body.trim().isNotEmpty) text,
          if (m.body.trim().isNotEmpty) const SizedBox(height: 8),
          _LinkPreviewCard(
            preview: preview,
            onOpen: () => _openUrl(preview.url),
          ),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: meta),
        ],
      );
    }

    // Let the meta flow right after the text: it tucks onto the same line for
    // short messages and drops to the bottom-right for ones that wrap — no
    // fixed gutter carving an empty column down the side.
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 6,
      runSpacing: 2,
      children: [text, meta],
    );
  }

  Widget _daySeparator(DateTime day) => _centerPill(
    _formatDaySeparator(day),
    key: ValueKey('day-${day.toIso8601String()}'),
  );

  Widget _gapHeader(DateTime t) => _centerPill(
    _formatGapHeader(t),
    key: ValueKey('gap-${t.toIso8601String()}'),
    fontSize: 11,
  );

  /// Centered translucent pill for day/gap headers — anchors the label over
  /// the wallpaper (iMessage/Telegram style) instead of bare text on lines.
  Widget _centerPill(String text, {required Key key, double fontSize = 12}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: context.palette.bgSurface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            text,
            style: TextStyle(
              color: context.palette.textMuted,
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// Group messages by day and insert separators for date changes and for
  /// gaps of >= 1 hour within a day.
  static List<_Item> _itemize(List<Msg> sorted) {
    const gapThreshold = Duration(hours: 1);
    final out = <_Item>[];
    DateTime? prevLocal;
    for (final m in sorted) {
      final local = m.ts.toLocal();
      if (prevLocal == null) {
        out.add(_DayItem(_dateOnly(local)));
      } else if (_dateOnly(local) != _dateOnly(prevLocal)) {
        out.add(_DayItem(_dateOnly(local)));
      } else if (local.difference(prevLocal) >= gapThreshold) {
        out.add(_GapItem(local));
      }
      out.add(_BubbleItem(m));
      prevLocal = local;
    }
    return out;
  }

  /// Build the status model: a per-message marker for each of my non-failed
  /// bubbles (heart when sent, clock when in flight), plus — for any run that
  /// contains a failure — a collapsed caption keyed to the run's trailing
  /// message so one tap retries every failed message in that run. A failure is
  /// never hidden: failed messages carry no in-bubble marker and always surface
  /// the caption.
  static _StatusModel _statusModel(List<Msg> sorted, String me) {
    final inBubble = <String, _Marker>{};
    final failedRun = <String, List<String>>{};
    var i = 0;
    while (i < sorted.length) {
      if (sorted[i].from != me) {
        i++;
        continue;
      }
      final failedIds = <String>[];
      String? lastFailedId;
      var j = i;
      while (j < sorted.length && sorted[j].from == me) {
        final m = sorted[j];
        switch (m.sendStatus) {
          case SendStatus.failed:
            failedIds.add(m.clientMsgId ?? m.id);
            lastFailedId = m.id;
          case SendStatus.sending:
            inBubble[m.id] = _Marker.sending;
          case SendStatus.sent:
            inBubble[m.id] = _Marker.sent;
          case SendStatus.read:
            inBubble[m.id] = _Marker.read;
        }
        j++;
      }
      if (lastFailedId != null) {
        failedRun[lastFailedId] = failedIds;
      }
      i = j;
    }
    return _StatusModel(inBubble, failedRun);
  }

  static DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  static String _formatDaySeparator(DateTime day) {
    final today = _dateOnly(DateTime.now());
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    final diff = today.difference(day).inDays;
    if (diff > 0 && diff < 7) return _weekdayName(day.weekday);
    if (day.year == today.year) return '${_monthName(day.month)} ${day.day}';
    return '${_monthName(day.month)} ${day.day}, ${day.year}';
  }

  static String _formatGapHeader(DateTime t) {
    return _formatTime(t);
  }

  /// Compact 24-hour, zero-padded time for the in-bubble stamp (e.g. 09:03).
  static String _formatHm(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _formatTime(DateTime t) {
    final h = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
    final m = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  static String _weekdayName(int wd) {
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[wd - 1];
  }

  static String _monthName(int month) {
    const names = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return names[month - 1];
  }

  /// Base body text size for message bubbles and the composer. iMessage body
  /// text is ~17pt; matching it also nudges inline emoji up a touch.
  static const double _bodyFontSize = 17;

  /// Number of visual emoji in [text] when it is emoji-only (whitespace
  /// allowed), else 0. Counts grapheme clusters, not runes, so a ZWJ family,
  /// flag, or skin-tone-modified emoji counts as one — matching what the eye
  /// sees. iMessage only enlarges 1–3 emoji; the caller uses this both to gate
  /// the jumbo treatment and to size it by count.
  static int _emojiOnlyCount(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 0;
    for (final r in trimmed.runes) {
      final ws = r == 0x20 || r == 0x0A || r == 0x09;
      if (!_runeIsEmoji(r) && !ws) return 0;
    }
    var count = 0;
    for (final g in trimmed.characters) {
      if (g.trim().isEmpty) continue;
      count++;
    }
    return count;
  }

  /// Frosted, darkened band behind the status bar + app-bar pills. Messages
  /// scroll under it and blur/darken so the OS clock/battery and the room title
  /// stay legible, Telegram-style. Drawn over the message list; pointer-through.
  ///
  /// Perf: a single `BackdropFilter` (not three stacked) — backdrop blur is a
  /// costly GPU pass on iOS, so one is plenty; the darker gradient carries the
  /// fade so the blur's lower edge isn't a hard line. Wrapped in a
  /// `RepaintBoundary` so an unrelated repaint elsewhere on the screen (the
  /// composer's blinking cursor, the typing dots) can't force the blur to
  /// re-composite every frame.
  Widget _topScrim(BuildContext context) {
    // Extend ~28px past the toolbar so the frost + darkening clear the bottom
    // of the title/action pills and fade out a few px below them, rather than
    // fading out right at the pills.
    final h = MediaQuery.of(context).padding.top + kToolbarHeight + 28;
    return Positioned(
      key: const Key('top-scrim'),
      top: 0,
      left: 0,
      right: 0,
      height: h,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Blur the top portion; the gradient below covers the blur's
              // bottom edge so there's no visible seam.
              _blurBand(top: 0, height: h * 0.82, sigma: 12),
              // Light darkening gradient (0x66 ≈ 40%) that holds through the
              // pills then fades out just below them — enough to keep the
              // clock/title legible over the wallpaper without reading heavy.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x66000000),
                      Color(0x66000000),
                      Color(0x00000000),
                    ],
                    stops: [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The frosted slice of the top scrim. Reuses the composer's saturation
  /// matrix so the glass material reads consistently across the screen.
  Widget _blurBand({
    required double top,
    required double height,
    required double sigma,
  }) {
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: height,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.compose(
            outer: const ColorFilter.matrix(_glassSaturation),
            inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Widget _composer() {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
          const _SendIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, control: true):
          const _SendIntent(),
    };
    // Floating frosted pill — no full-width slab. The message list scrolls
    // straight up behind the composer with wallpaper showing through the
    // gutters; the glass lives in the pill itself (and the idle mic), so it
    // reads as a translucent chip hovering over the chat, Telegram-style.
    //
    // No tap-to-dismiss TapRegion wraps this: it fired on the pointer-down
    // that begins a scroll, snapping the keyboard shut the instant you touched
    // the list. Tap-to-dismiss now lives on the message list as a GestureDetector
    // onTap, which loses the gesture arena to a scroll drag — so you can scroll
    // history with the keyboard up.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_editingId != null) _editBanner(),
            if (_replyDraft != null) _replyBanner(),
            if (_staged.isNotEmpty) _stagingTray(),
            // Scope recorder-driven rebuilds (timer + live waveform fire
            // ~15×/sec) to the composer only, so the message list isn't
            // re-sorted/re-itemized on every tick while recording.
            ListenableBuilder(
              listenable: _recorder,
              builder: (context, _) => Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // The pill: one rounded glass surface holding the attach
                  // action (inside-left, bottom-pinned) and the text field.
                  // Bottom alignment keeps the attach glyph on the last line as
                  // the field grows, instead of drifting to the vertical center.
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: BackdropFilter(
                        // Apple-style material: blur the messages behind, then
                        // lift their saturation back up (ColorFilter implements
                        // ImageFilter, so compose() chains it over the blur) so
                        // the glass stays luminous instead of going muddy.
                        filter: ImageFilter.compose(
                          outer: const ColorFilter.matrix(_glassSaturation),
                          inner: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: context.palette.bgSurface.withValues(
                              alpha: 0.55,
                            ),
                            borderRadius: BorderRadius.circular(22),
                            // Hairline all the way around so the glass edge
                            // reads crisply against messages passing behind it.
                            border: Border.all(
                              color: context.palette.textPrimary.withValues(
                                alpha: 0.10,
                              ),
                              width: 0.5,
                            ),
                          ),
                          // Recording keeps the pill in place — only its
                          // content swaps to the live waveform strip.
                          child:
                              _recorder.state == RecorderState.recording ||
                                  _recorder.state == RecorderState.locked
                              ? _recordingStrip()
                              : Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (widget.onPickMedia != null)
                                      IconButton(
                                        key: const Key('composer-attach'),
                                        onPressed: _pickMedia,
                                        icon: Icon(
                                          Icons.attach_file,
                                          color: context.palette.textMuted,
                                          size: 22,
                                        ),
                                        tooltip: 'Attach a photo or video',
                                      ),
                                    Expanded(
                                      child: Shortcuts(
                                        shortcuts: shortcuts,
                                        child: Actions(
                                          actions: {
                                            _SendIntent:
                                                CallbackAction<_SendIntent>(
                                                  onInvoke: (_) {
                                                    _submitFromIntent();
                                                    return null;
                                                  },
                                                ),
                                          },
                                          child: TextField(
                                            key: const Key('composer'),
                                            controller: _controller,
                                            focusNode: _composerFocus,
                                            onChanged: _onComposerChanged,
                                            // Match the bubble body (~17pt) so
                                            // what you type is the size it sends
                                            // at.
                                            style: TextStyle(
                                              fontSize: _bodyFontSize,
                                              color:
                                                  context.palette.textPrimary,
                                            ),
                                            minLines: 1,
                                            maxLines: 10,
                                            keyboardType:
                                                TextInputType.multiline,
                                            textInputAction:
                                                TextInputAction.newline,
                                            // Match iMessage/Telegram: capitalize
                                            // the first letter of each sentence.
                                            textCapitalization:
                                                TextCapitalization.sentences,
                                            decoration: InputDecoration(
                                              isDense: true,
                                              hintText: 'Message',
                                              hintStyle: TextStyle(
                                                color:
                                                    context.palette.textMuted,
                                              ),
                                              border: InputBorder.none,
                                              // Lead padding only when the attach
                                              // button isn't there to provide it.
                                              contentPadding:
                                                  EdgeInsets.fromLTRB(
                                                    widget.onPickMedia != null
                                                        ? 0
                                                        : 16,
                                                    11,
                                                    16,
                                                    11,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _trailingButton(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Single trailing control that morphs between an idle mic affordance and
  /// the active send button, Telegram-style. A cross-fade (not a scale) keeps
  /// whichever child is showing at full layout size, so it stays tappable the
  /// frame it appears.
  Widget _trailingButton() {
    // Locked (hands-free) recording: the trailing becomes a voice send. While a
    // press-and-hold is still in flight we leave the normal mic path untouched
    // so the active gesture isn't torn out from under the finger.
    if (_recorder.state == RecorderState.locked) return _voiceSendButton();
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final hasContent = value.text.trim().isNotEmpty || _staged.isNotEmpty;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: hasContent ? _sendButton() : _micButton(),
        );
      },
    );
  }

  /// The in-pill recording strip (red dot + timer + live waveform), shown while
  /// the composer is capturing a voice memo. The chat bar stays put.
  Widget _recordingStrip() {
    return RecordingStrip(
      elapsed: _recorder.elapsed,
      locked: _recorder.state == RecorderState.locked,
      cancelArmed: _cancelArmed,
      waveform: downsampleWaveform(_recorder.recentAmplitudes(), buckets: 28),
      barColor: context.palette.textPrimary,
      hintColor: context.palette.textMuted,
      onTrash: () => _recorder.cancel(),
    );
  }

  /// Filled circular send for a locked voice recording: stop + fan out.
  Widget _voiceSendButton() {
    return Material(
      key: const Key('recording-send'),
      color: context.palette.accentUser,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          final rec = await _recorder.stop();
          if (rec != null) await _sendVoiceMemo(rec);
        },
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.arrow_upward, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  /// Filled circular send.
  Widget _sendButton() {
    return Material(
      key: const Key('composer-send'),
      color: context.palette.accentUser,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _handleSubmit(_controller.text),
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.arrow_upward, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  /// Idle-state mic affordance. Press-and-hold to record a voice memo,
  /// Telegram-style: slide left past the threshold to cancel, slide up to lock
  /// for hands-free recording, release to stop + send. When [onSendVoice] is
  /// null the gesture is disabled and a tap just signals it's unavailable.
  Widget _micButton() {
    final enabled = widget.onSendVoice != null;
    return GestureDetector(
      key: const Key('composer-mic'),
      // Opaque so the whole 44×44 circle reliably receives tap + long-press,
      // not just the painted glyph.
      behavior: HitTestBehavior.opaque,
      // Tap = hands-free recording (WhatsApp / new-Telegram): start, then lock
      // so the overlay shows stop/send/trash without holding. Press-and-hold
      // (below) remains the release-to-send gesture.
      onTap: enabled
          ? () async {
              if (await _recorder.start()) {
                _recorder.lock();
              } else if (mounted) {
                _showMicPermissionDenied();
              }
            }
          : () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Voice messages are coming soon'),
                duration: Duration(seconds: 2),
              ),
            ),
      onLongPressStart: enabled
          ? (_) async {
              _cancelArmed = false;
              _startFuture = _recorder.start();
              if (!await _startFuture! && mounted) {
                _showMicPermissionDenied();
              }
            }
          : null,
      onLongPressMoveUpdate: enabled
          ? (d) {
              final dx = d.offsetFromOrigin.dx;
              final dy = d.offsetFromOrigin.dy;
              if (dy < -80) _recorder.lock();
              if (_cancelArmed != (dx < -80)) {
                setState(() => _cancelArmed = dx < -80);
              }
            }
          : null,
      onLongPressEnd: enabled
          ? (_) async {
              // A quick tap-and-release can fire before the async start() has
              // flipped state to recording; await it first so stop() doesn't
              // no-op and silently drop (and orphan) the capture.
              await _startFuture;
              // Locked recording is finished via the overlay's stop/send
              // buttons, not the release of this press.
              if (_recorder.state == RecorderState.locked) return;
              if (_cancelArmed) {
                await _recorder.cancel();
              } else {
                final rec = await _recorder.stop();
                if (rec != null) await _sendVoiceMemo(rec);
              }
            }
          : null,
      child: _micGlassCircle(),
    );
  }

  /// Surface a denied/undetermined mic permission instead of failing silently
  /// (the recorder just stays idle, which otherwise reads as a dead button).
  void _showMicPermissionDenied() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Microphone access is off — turn it on in Settings to send voice '
          'messages.',
        ),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// The frosted glass circle visual (matching the composer pill) used as the
  /// mic affordance.
  Widget _micGlassCircle() {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: const ColorFilter.matrix(_glassSaturation),
          inner: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        ),
        child: Material(
          color: context.palette.bgSurface.withValues(alpha: 0.55),
          shape: const CircleBorder(
            side: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
          ),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.mic, color: context.palette.textMuted, size: 24),
          ),
        ),
      ),
    );
  }

  /// Horizontal strip of staged media above the composer. Each chip shows a
  /// preview (image bytes, or a play badge for video) with a remove button.
  /// The "Editing message" banner shown above the composer while in edit mode:
  /// a pencil, the original text (one line), and an ✕ to cancel back to normal
  /// compose.
  Widget _editBanner() {
    final palette = context.palette;
    return Container(
      key: const Key('edit-banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: palette.bgSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: palette.accentUser, width: 3)),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_outlined, size: 18, color: palette.accentUser),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.accentUser,
                  ),
                ),
                Text(
                  _editingOriginal,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('edit-cancel'),
            icon: const Icon(Icons.close, size: 20),
            color: palette.textMuted,
            visualDensity: VisualDensity.compact,
            onPressed: _cancelEdit,
            tooltip: 'Cancel edit',
          ),
        ],
      ),
    );
  }

  Widget _replyBanner() {
    final palette = context.palette;
    final r = _replyDraft!;
    return Container(
      key: const Key('reply-banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: palette.bgSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: palette.accentSage, width: 3)),
      ),
      child: Row(
        children: [
          Icon(Icons.reply, size: 18, color: palette.accentSage),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to ${_replyAuthorLabel(r.author)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.accentSage,
                  ),
                ),
                Text(
                  _replyPreviewText(r),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('reply-cancel'),
            icon: const Icon(Icons.close, size: 20),
            color: palette.textMuted,
            visualDensity: VisualDensity.compact,
            onPressed: _cancelReply,
            tooltip: 'Cancel reply',
          ),
        ],
      ),
    );
  }

  Widget _stagingTray() {
    return Container(
      key: const Key('staging-tray'),
      height: 76,
      margin: const EdgeInsets.only(bottom: 8),
      alignment: Alignment.centerLeft,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _staged.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) =>
            _StagedChip(item: _staged[i], onRemove: () => _removeStaged(i)),
      ),
    );
  }
}

/// Top-bar status for the conversation: the partner's "Typing…" with gently
/// pulsing dots while they compose, and nothing when idle. Living in the app
/// bar (not as a list row) keeps the partner's typing state from reflowing the
/// message list — which otherwise nudged the list on send.
/// The status line under the room name in the title pill. Shows "typing" with
/// animated dots while the partner is composing; otherwise the partner's
/// online / offline presence. Empty when there's no partner (a solo room).
class _PartnerStatusLine extends ConsumerStatefulWidget {
  const _PartnerStatusLine({required this.roomId, required this.partner});
  final String roomId;
  final String? partner;

  @override
  ConsumerState<_PartnerStatusLine> createState() => _PartnerStatusLineState();
}

class _PartnerStatusLineState extends ConsumerState<_PartnerStatusLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Recompute the relative "last seen …" label once a minute so it advances
    // (e.g. "5 minutes ago" → "6 minutes ago") without any new network traffic.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = ref.watch(typingProvider(widget.roomId));
    if (typing) {
      return Row(
        key: const Key('typing-indicator'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'typing',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w500,
              color: context.palette.accentSage,
            ),
          ),
          const SizedBox(width: 5),
          const _PulsingDots(),
        ],
      );
    }
    if (widget.partner == null) return const SizedBox.shrink();
    final presence = ref.watch(presenceProvider(widget.partner!));
    final online = presence.online;
    final tone = online
        ? context.palette.accentSage
        : context.palette.textMuted;

    final String label;
    if (online) {
      label = 'online';
    } else if (presence.lastSeen != null) {
      label = lastSeenLabel(presence.lastSeen!, now: DateTime.now());
    } else {
      label = 'offline';
    }

    return Row(
      key: const Key('presence-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            letterSpacing: 0.3,
            fontWeight: FontWeight.w500,
            color: tone,
          ),
        ),
      ],
    );
  }
}

/// Three sage dots whose opacity pulses in a gentle staggered wave (no bounce).
class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Opacity(
                  // Staggered sine pulse: each dot fades out of phase, 0.25→1.
                  opacity:
                      (0.25 +
                              0.75 *
                                  math.sin(
                                    ((_c.value + i * 0.2) % 1.0) * math.pi,
                                  ))
                          .clamp(0.0, 1.0),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: context.palette.accentSage,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A tappable link-preview card under a message: optional banner image, then
/// site name, title, and a short description — Telegram-style, with a sage
/// accent bar down the left. All data is embedded in the message (see
/// [LinkPreview]); tapping opens the URL in the browser.
class _LinkPreviewCard extends StatefulWidget {
  const _LinkPreviewCard({required this.preview, required this.onOpen});
  final LinkPreview preview;
  final VoidCallback onOpen;

  @override
  State<_LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<_LinkPreviewCard> {
  // Decode the embedded image once and hold the same bytes instance: decoding
  // in build would hand Image.memory a fresh Uint8List each frame, missing the
  // image cache and re-decoding on every scroll tick (a visible flash).
  Uint8List? _imageBytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant _LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.preview.imageB64 != widget.preview.imageB64) _decode();
  }

  void _decode() {
    final b64 = widget.preview.imageB64;
    _imageBytes = (b64 == null || b64.isEmpty) ? null : base64.decode(b64);
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final bytes = _imageBytes;
    return GestureDetector(
      onTap: widget.onOpen,
      child: Container(
        key: const Key('link-preview-card'),
        constraints: const BoxConstraints(maxWidth: 300),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: context.palette.bgSurfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(color: context.palette.accentSage, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bytes != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  // Show the whole image at its real aspect ratio (Telegram-
                  // style dynamic height) instead of cropping to a fixed band.
                  // Clamp only the extremes so a very tall image can't make a
                  // giant card.
                  final w = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : 300.0;
                  final iw = preview.imageWidth, ih = preview.imageHeight;
                  final aspect = (iw != null && ih != null && iw > 0 && ih > 0)
                      ? iw / ih
                      : 1.91; // OG default banner ratio
                  final h = (w / aspect).clamp(120.0, 360.0);
                  return Image.memory(
                    bytes,
                    width: w,
                    height: h,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  );
                },
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preview.siteName != null && preview.siteName!.isNotEmpty)
                    Text(
                      preview.siteName!.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600,
                        color: context.palette.accentSage,
                      ),
                    ),
                  if (preview.title != null && preview.title!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        preview.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: context.palette.textPrimary,
                        ),
                      ),
                    ),
                  if (preview.description != null &&
                      preview.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        preview.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.palette.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A reaction pill under a bubble: the emoji plus a count when more than one
/// person reacted with it. Highlighted when it's the viewer's own reaction.
class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine
              ? context.palette.accentUser.withValues(alpha: 0.18)
              : context.palette.bgSurfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine
                ? context.palette.accentUser
                : context.palette.borderSoft,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.0,
                // Split the line's leading evenly so the glyph sits centered
                // rather than baseline-low (emoji metrics are top-heavy).
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            if (count > 1) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen overlay holding the floating quick-reaction bar. A transparent
/// layer behind it dismisses on tap-outside; the bar scales + fades in from the
/// anchored bubble, Telegram style.
class _ReactionBarOverlay extends StatefulWidget {
  const _ReactionBarOverlay({
    required this.anchor,
    required this.selected,
    required this.showReactions,
    required this.onPick,
    required this.onMore,
    required this.onReply,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
    required this.onSaveMedia,
    required this.onShareMedia,
    required this.onDismiss,
  });
  final Offset anchor;
  final String? selected;
  final bool showReactions;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;
  final VoidCallback? onReply;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onSaveMedia;
  final VoidCallback? onShareMedia;
  final VoidCallback onDismiss;

  @override
  State<_ReactionBarOverlay> createState() => _ReactionBarOverlayState();
}

class _ReactionBarOverlayState extends State<_ReactionBarOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    const menuWidth = 296.0;
    const reactionRow = 48.0 + 8.0; // bar + gap below it
    final actionCount =
        (widget.onReply != null ? 1 : 0) +
        (widget.onCopy != null ? 1 : 0) +
        (widget.onEdit != null ? 1 : 0) +
        (widget.onSaveMedia != null ? 1 : 0) +
        (widget.onShareMedia != null ? 1 : 0) +
        (widget.onDelete != null ? 1 : 0);
    final actionsHeight = actionCount == 0 ? 0.0 : actionCount * 44.0 + 8.0;
    final totalHeight =
        (widget.showReactions ? reactionRow : 0.0) + actionsHeight;
    final left = (widget.anchor.dx - menuWidth / 2).clamp(
      8.0,
      size.width - menuWidth - 8.0,
    );
    // Prefer sitting just above the press point; if that would clip the top,
    // flip below it. Then clamp so a tall menu never runs off either edge.
    var top = widget.anchor.dy - totalHeight - 12;
    if (top < padding.top + 8) top = widget.anchor.dy + 12;
    top = top.clamp(
      padding.top + 8,
      (size.height - totalHeight - padding.bottom - 8).clamp(
        padding.top + 8,
        double.infinity,
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: ScaleTransition(
            scale: CurvedAnimation(parent: _c, curve: Curves.easeOutBack),
            alignment: Alignment.topCenter,
            child: FadeTransition(
              opacity: _c,
              child: SizedBox(
                width: menuWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showReactions) _bar(),
                    if (actionCount > 0) ...[
                      const SizedBox(height: 8),
                      _actions(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bar() {
    return Material(
      key: const Key('reaction-bar'),
      elevation: 8,
      borderRadius: BorderRadius.circular(26),
      color: context.palette.bgSurface,
      surfaceTintColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in _quickReactions) _emojiButton(e),
            _moreButton(),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    return Material(
      key: const Key('message-actions'),
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      color: context.palette.bgSurface,
      surfaceTintColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onReply != null)
              _actionItem(
                key: 'action-reply',
                icon: Icons.reply,
                label: 'Reply',
                onTap: widget.onReply!,
              ),
            if (widget.onCopy != null)
              _actionItem(
                key: 'action-copy',
                icon: Icons.copy_outlined,
                label: 'Copy',
                onTap: widget.onCopy!,
              ),
            if (widget.onEdit != null)
              _actionItem(
                key: 'action-edit',
                icon: Icons.edit_outlined,
                label: 'Edit',
                onTap: widget.onEdit!,
              ),
            if (widget.onSaveMedia != null)
              _actionItem(
                key: 'action-save-media',
                icon: Icons.download_rounded,
                label: 'Save to Photos',
                onTap: widget.onSaveMedia!,
              ),
            if (widget.onShareMedia != null)
              _actionItem(
                key: 'action-share-media',
                icon: Icons.ios_share,
                label: 'Share',
                onTap: widget.onShareMedia!,
              ),
            if (widget.onDelete != null)
              _actionItem(
                key: 'action-delete',
                icon: Icons.delete_outline,
                label: 'Delete',
                color: context.palette.warningTone,
                onTap: widget.onDelete!,
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionItem({
    required String key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final c = color ?? context.palette.textPrimary;
    return InkWell(
      key: Key(key),
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 16, color: c)),
            ),
            Icon(icon, size: 20, color: c),
          ],
        ),
      ),
    );
  }

  Widget _emojiButton(String emoji) {
    final isSelected = emoji == widget.selected;
    return GestureDetector(
      onTap: () => widget.onPick(emoji),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? context.palette.accentUser.withValues(alpha: 0.18)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Text(
          emoji,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            height: 1.0,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }

  Widget _moreButton() {
    return GestureDetector(
      onTap: widget.onMore,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        child: Icon(Icons.add, color: context.palette.textMuted),
      ),
    );
  }
}

/// A single staged-media chip in the composer tray: a square preview with a
/// remove (×) button. Images render their bytes inline; videos extract a poster
/// frame (async) and overlay a play badge, falling back to a neutral fill while
/// the frame is being decoded.
class _StagedChip extends StatefulWidget {
  const _StagedChip({required this.item, required this.onRemove});
  final StagedAttachment item;
  final VoidCallback onRemove;

  @override
  State<_StagedChip> createState() => _StagedChipState();
}

class _StagedChipState extends State<_StagedChip> {
  Future<Uint8List?>? _poster;

  @override
  void initState() {
    super.initState();
    final path = widget.item.videoPath;
    if (widget.item.isVideo && path != null) {
      _poster = _buildPoster(path);
    }
  }

  Future<Uint8List?> _buildPoster(String path) async {
    try {
      return (await buildVideoThumbnail(path)).jpeg;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(width: 64, height: 64, child: _preview()),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: widget.onRemove,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xCC140C12),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(2),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    if (!widget.item.isVideo) {
      // Decode at tile resolution, not full-res: the chip is 64pt (~192px on a
      // 3× screen), so cap the decoded bitmap at 256px. Without this a multi-
      // pick of large photos decodes each one to a full-resolution RGBA bitmap
      // (tens of MB apiece) just to paint a thumbnail — a real jetsam path on a
      // 3 GB iPhone. The raw bytes still ride on the item for send/encrypt.
      return Image.memory(
        widget.item.bytes,
        fit: BoxFit.cover,
        cacheWidth: 256,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<Uint8List?>(
          future: _poster,
          builder: (_, snap) => snap.data != null
              ? Image.memory(snap.data!, fit: BoxFit.cover, cacheWidth: 256)
              : Container(color: context.palette.bgSurfaceAlt),
        ),
        const Center(child: _PlayBadge(size: 26)),
      ],
    );
  }
}

class _MediaBubble extends StatelessWidget {
  const _MediaBubble({
    required this.msg,
    required this.isMe,
    required this.marker,
    required this.onOpen,
  });
  final Msg msg;
  final bool isMe;
  final _Marker? marker;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final d = msg.attachment!;
    final aspect = (d.width > 0 && d.height > 0) ? d.width / d.height : 4 / 3;
    final sending = msg.sendStatus == SendStatus.sending;
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isMe
              ? context.palette.bubbleUserBg
              : context.palette.bubblePartnerBg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: aspect.clamp(0.6, 1.9),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Video keeps its poster thumb; a photo loads the full
                    // decrypted image (thumb shown until it arrives) so the
                    // tile is sharp rather than an upscaled thumbnail.
                    d.isVideo
                        ? _ThumbImage(thumbB64: d.thumbB64)
                        : _MediaImage(descriptor: d),
                    if (d.isVideo) const Center(child: _PlayBadge()),
                    if (sending)
                      Container(
                        color: const Color(0x57F4EBEC),
                        child: const Center(
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                      ),
                    // Time + read marker, on a scrim over the image bottom-right
                    // (the spinner already conveys the in-flight state).
                    if (!sending)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: _MediaMeta(
                          time: _ConversationPageState._formatHm(
                            msg.ts.toLocal(),
                          ),
                          marker: marker,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Caption (the message sent with the media) renders under the tile,
            // keeping the photo + words in one bubble.
            if (msg.body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 4, 2),
                child: Text(
                  msg.body,
                  style: TextStyle(
                    color: isMe
                        ? context.palette.bubbleUserText
                        : context.palette.textPrimary,
                    fontSize: 15,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small time + read-marker chip on a dark scrim, sat over a media tile's
/// bottom-right corner so the timestamp and hearts read against any image.
class _MediaMeta extends StatelessWidget {
  const _MediaMeta({required this.time, required this.marker});
  final String time;
  final _Marker? marker;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0x73000000),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(time, style: const TextStyle(fontSize: 10, color: Colors.white)),
          if (marker != null) ...[
            const SizedBox(width: 4),
            _ConversationPageState._markerWidget(marker!, context.palette),
          ],
        ],
      ),
    );
  }
}

/// Decodes + decrypts the inline thumb (FutureBuilder; tiny, fast).
class _ThumbImage extends StatefulWidget {
  const _ThumbImage({required this.thumbB64});
  final String thumbB64;
  @override
  State<_ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<_ThumbImage> {
  late final Future<Uint8List> _bytes = decodeThumb(widget.thumbB64);
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (_, snap) {
        if (snap.hasData) {
          return Image.memory(
            snap.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // The thumb is still upscaled into the tile; medium filtering
            // smooths that far better than the default (nearest-ish).
            filterQuality: FilterQuality.medium,
          );
        }
        return Container(color: context.palette.bgSurfaceAlt);
      },
    );
  }
}

/// A photo tile: shows the tiny inline thumb instantly as a placeholder, then
/// fetches + decrypts the full image (disk-cached by [fetchAndDecrypt]) and
/// cross-fades it in so the tile is crisp instead of an upscaled thumbnail —
/// the same placeholder-then-full pattern WhatsApp/Telegram use. The full
/// bytes never leave E2EE: they're pulled from the blob store with the
/// per-file key already in the (decrypted) descriptor.
class _MediaImage extends ConsumerStatefulWidget {
  const _MediaImage({required this.descriptor});
  final AttachmentDescriptor descriptor;
  @override
  ConsumerState<_MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends ConsumerState<_MediaImage> {
  // Decrypted full-res files, cached across rebuilds/scroll by blob key so a
  // tile that scrolls off and back doesn't re-read from disk.
  static final Map<String, File> _fileCache = {};
  File? _file;
  bool _loading = false;

  // A fetch failed and we've stopped auto-retrying. Without this, every
  // `liveConnectionProvider` rebuild after a failure re-issued a network +
  // decrypt for the tile, hammering a flaky connection. Cleared only by an
  // explicit tap (see [_retry]).
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _file = _fileCache[widget.descriptor.blobKey];
  }

  Future<void> _load(LiveConnection conn) async {
    try {
      final file = await fetchAndDecrypt(
        conn: conn,
        descriptor: widget.descriptor,
      );
      _fileCache[widget.descriptor.blobKey] = file;
      if (mounted) setState(() => _file = file);
    } catch (_) {
      // Stop the auto-retry loop: leave the thumb placeholder and wait for an
      // explicit tap rather than re-fetching on every rebuild.
      if (mounted) setState(() => _failed = true);
      _loading = false;
    }
  }

  void _retry() {
    if (_file != null) return;
    setState(() {
      _failed = false;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watch the socket so the fetch fires as soon as it's ready — reading it
    // once in initState raced the connection and could strand the tile on the
    // low-res thumb forever. A prior failure pins us on the placeholder until
    // the user taps to retry.
    if (_file == null && !_loading && !_failed) {
      final conn = ref.watch(liveConnectionProvider).asData?.value;
      if (conn != null) {
        _loading = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _load(conn));
      }
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _file == null
          ? GestureDetector(
              onTap: _failed ? _retry : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _ThumbImage(thumbB64: widget.descriptor.thumbB64),
                  if (_failed)
                    const ColoredBox(
                      color: Color(0x40000000),
                      child: Center(
                        child: Icon(
                          Icons.refresh,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                ],
              ),
            )
          : Image.file(
              _file!,
              key: ValueKey(widget.descriptor.blobKey),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              // Cap the decoded bitmap; the tile is small, so 1080px wide is
              // plenty sharp without holding a full-resolution image in memory.
              cacheWidth: 1080,
            ),
    );
  }
}

/// Paints a chat bubble: a rounded rectangle with a small tail curling out of
/// the bottom corner on the sender's side — right for my messages, left for the
/// partner's — like iMessage. The tail isn't a flat flare: the edge runs down
/// past the corner, pokes out to the box edge, then *hooks back inward* with a
/// little curl (the control points dip just past the bottom edge). The body
/// fills the full box; the tail lives entirely inside the bottom corner.
class _BubbleBackground extends CustomPainter {
  const _BubbleBackground({
    required this.color,
    required this.border,
    required this.mine,
  });

  final Color color;
  final Color border;
  final bool mine;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// The canonical iMessage bubble path: 15px rounded corners on three sides,
  /// and a curled tail at the bottom corner on the sender's side. Coordinates
  /// are the fixed pixel landmarks from Apple's shape (tail spans ~20px), so it
  /// reads identically at any bubble size.
  Path _path(Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path();
    if (mine) {
      // Tail at the bottom-right; mirror of the received geometry (x -> w - x).
      path
        ..moveTo(w - 20, h)
        ..lineTo(15, h)
        ..cubicTo(8, h, 0, h - 8, 0, h - 15) // bottom-left corner
        ..lineTo(0, 15)
        ..cubicTo(0, 8, 8, 0, 15, 0) // top-left corner
        ..lineTo(w - 20, 0)
        ..cubicTo(w - 12, 0, w - 5, 8, w - 5, 15) // top-right corner
        ..lineTo(w - 5, h - 10) // right edge runs down past the corner
        ..cubicTo(w - 5, h - 1, w, h, w, h) // poke out to the tail tip
        ..cubicTo(w - 4, h + 1, w - 8, h - 1, w - 12, h - 4) // curl back in
        ..cubicTo(w - 15, h - 1, w - 18, h, w - 20, h) // rejoin bottom edge
        ..close();
    } else {
      // Tail at the bottom-left (received).
      path
        ..moveTo(20, h)
        ..lineTo(w - 15, h)
        ..cubicTo(w - 8, h, w, h - 8, w, h - 15) // bottom-right corner
        ..lineTo(w, 15)
        ..cubicTo(w, 8, w - 8, 0, w - 15, 0) // top-right corner
        ..lineTo(20, 0)
        ..cubicTo(12, 0, 5, 8, 5, 15) // top-left corner
        ..lineTo(5, h - 10) // left edge runs down past the corner
        ..cubicTo(5, h - 1, 0, h, 0, h) // poke out to the tail tip
        ..cubicTo(4, h + 1, 8, h - 1, 12, h - 4) // curl back in
        ..cubicTo(15, h - 1, 18, h, 20, h) // rejoin bottom edge
        ..close();
    }
    return path;
  }

  @override
  bool shouldRepaint(_BubbleBackground old) =>
      old.color != color || old.border != border || old.mine != mine;
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge({this.size = 52});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0x6B140C12),
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xBFFFFFFF), width: 1.5),
    ),
    child: Icon(
      Icons.play_arrow_rounded,
      color: Colors.white,
      size: size * 0.58,
    ),
  );
}

/// One-shot "pop" for a newly-arrived message: a quick scale-up from the
/// bubble's own bottom corner plus a fade. Runs once on first build of the
/// subtree — [TweenAnimationBuilder] fires when the end value first appears and
/// does not re-run while it stays constant, so a plain rebuild won't replay it.
class _PopIn extends StatelessWidget {
  const _PopIn({super.key, required this.child, required this.alignEnd});

  final Widget child;

  /// Own messages grow from the bottom-right; partner messages bottom-left.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, t, child) {
        final scale = 0.85 + 0.15 * t;
        // easeOutBack overshoots past 1.0; clamp opacity so it never exceeds 1.
        final opacity = t.clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            alignment: alignEnd ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Swipe-to-reply: drags a bubble horizontally toward screen center (own
/// bubbles left, partner's right), revealing a reply arrow. Releasing past the
/// threshold fires [onReply]; the bubble springs back either way. Vertical
/// scrolling is untouched — only horizontal drags are claimed.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({
    required this.mine,
    required this.onReply,
    required this.child,
  });

  final bool mine;
  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _threshold = 56.0;
  static const _maxDrag = 80.0;
  double _dx = 0;
  bool _armed = false;

  void _update(DragUpdateDetails d) {
    // Own bubbles pull left (negative), partner's pull right (positive); ignore
    // drags in the wrong direction so the gesture only ever opens inward.
    final next = _dx + d.delta.dx;
    final clamped = widget.mine
        ? next.clamp(-_maxDrag, 0.0)
        : next.clamp(0.0, _maxDrag);
    final armed = clamped.abs() >= _threshold;
    if (armed && !_armed) HapticFeedback.lightImpact();
    setState(() {
      _dx = clamped;
      _armed = armed;
    });
  }

  void _end(DragEndDetails _) {
    if (_armed) widget.onReply();
    setState(() {
      _dx = 0;
      _armed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dx.abs() / _threshold).clamp(0.0, 1.0);
    return Stack(
      alignment: widget.mine ? Alignment.centerRight : Alignment.centerLeft,
      children: [
        Positioned(
          left: widget.mine ? null : 12,
          right: widget.mine ? 12 : null,
          child: Opacity(
            opacity: progress,
            child: Icon(
              Icons.reply,
              size: 20,
              color: context.palette.accentSage,
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: _end,
          child: AnimatedContainer(
            // Snap back smoothly on release (_dx → 0); track the finger live.
            duration: _dx == 0
                ? const Duration(milliseconds: 160)
                : Duration.zero,
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// iMessage-style focused thread view: the chat blurs behind a scrim while just
/// one thread (a root message + its transitive replies) is shown, with a
/// composer that replies straight back into the thread. Self-contained
/// rendering (it does not reuse the timeline bubbles, which hold GlobalKeys
/// still mounted behind the blur).
class _ThreadFocusView extends ConsumerStatefulWidget {
  const _ThreadFocusView({
    required this.roomId,
    required this.rootId,
    required this.me,
    required this.onSend,
  });

  final String roomId;
  final String rootId;
  final String me;
  final void Function(String text) onSend;

  @override
  ConsumerState<_ThreadFocusView> createState() => _ThreadFocusViewState();
}

class _ThreadFocusViewState extends ConsumerState<_ThreadFocusView> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  /// Last rendered thread length, so a grow (new reply, mine or the partner's)
  /// triggers a stick-to-bottom.
  int _lastCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Pin the list to the newest message once it's laid out. Jumps on the first
  /// build (open), animates afterward so a fresh reply slides into view.
  void _stickToBottom({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  /// The root plus its transitive replies, chronological. Recomputed from the
  /// live store so replies sent while focused appear immediately.
  List<Msg> _thread(List<Msg> all) {
    final byParent = <String, List<Msg>>{};
    Msg? root;
    for (final m in all) {
      if (m.id == widget.rootId) root = m;
      final p = m.replyTo?.id;
      if (p != null) (byParent[p] ??= <Msg>[]).add(m);
    }
    if (root == null) return const [];
    final out = <Msg>[root];
    final queue = <String>[root.id];
    while (queue.isNotEmpty) {
      for (final child in byParent[queue.removeLast()] ?? const <Msg>[]) {
        out.add(child);
        queue.add(child.id);
      }
    }
    out.sort((a, b) => a.ts.compareTo(b.ts));
    return out;
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final thread = _thread(ref.watch(messageStoreProvider(widget.roomId)));
    // The root was unsent out from under us: close.
    if (thread.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    // Stick to the bottom on open and whenever the thread grows.
    if (thread.length != _lastCount) {
      _stickToBottom(animate: _lastCount != 0);
      _lastCount = thread.length;
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Blur + dim the chat behind; tap outside the sheet to dismiss.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(color: Colors.black.withValues(alpha: 0.12)),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _header(palette),
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    itemCount: thread.length,
                    itemBuilder: (_, i) => _threadBubble(thread[i], palette),
                  ),
                ),
                _composer(palette),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            color: palette.textPrimary,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Text(
            'Thread',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _threadBubble(Msg m, AppPalette palette) {
    final mine = m.from == widget.me;
    final att = m.attachment;
    final String text;
    if (att != null) {
      final label = att.isVideo
          ? 'Video'
          : att.isAudio
          ? 'Voice message'
          : att.mime.startsWith('image/')
          ? 'Photo'
          : 'File';
      final caption = m.body.trim();
      text = caption.isEmpty ? label : '$label · $caption';
    } else {
      text = m.body;
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.72,
        ),
        decoration: BoxDecoration(
          color: mine ? palette.bubbleUserBg : palette.bubblePartnerBg,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 15, color: palette.textPrimary),
        ),
      ),
    );
  }

  Widget _composer(AppPalette palette) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('thread-composer'),
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: TextStyle(color: palette.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Reply to thread',
                  filled: true,
                  fillColor: palette.bgSurface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('thread-send'),
              icon: Icon(Icons.send, color: palette.accentSage),
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }
}
