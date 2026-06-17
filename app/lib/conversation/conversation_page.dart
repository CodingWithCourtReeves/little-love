import 'dart:async';
import 'dart:math' as math;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/staged_attachment.dart';
import '../identity/providers.dart';
import '../inbox/channel_switcher.dart';
import '../inbox/room.dart';
import '../theme/twilight.dart';
import '../wire/message.dart';
import 'message_store.dart';
import 'typing_state.dart';

typedef SendCallback = void Function(String text);
typedef RenameCallback = void Function(String newName);
typedef RetryCallback = void Function(String clientMsgId);
typedef OpenAttachmentCallback = void Function(AttachmentDescriptor descriptor);
typedef ReactCallback = void Function(String targetMessageId, String emoji);

/// Quick-tap reactions in the long-press bar, Telegram style. The first is the
/// double-tap default.
const _quickReactions = ['❤️', '👍', '😂', '😮', '😢', '🙏'];

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

/// Bottom-of-chat placeholder for the partner's live "typing…" bubble.
class _TypingItem extends _Item {
  const _TypingItem();
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
    this.onNewChannel,
    this.onRetry,
    this.onPickMedia,
    this.onSendMedia,
    this.onReact,
    this.onTyping,
    this.onOpenAttachment,
  });

  final Room room;
  final String selfUsername;
  final SendCallback onSend;
  final RenameCallback? onRename;
  final VoidCallback? onNewChannel;
  final RetryCallback? onRetry;

  /// Tapped the composer's attach (+) button: pick media to stage on the
  /// composer (not send yet). Returns the picked items. Null disables the
  /// affordance.
  final Future<List<StagedAttachment>> Function()? onPickMedia;

  /// Send the staged media. The caption (composer text, may be empty) attaches
  /// to the last item so a multi-pick reads as one captioned run.
  final Future<void> Function(List<StagedAttachment> items, String caption)?
  onSendMedia;

  /// React to a message (empty emoji = remove my reaction). Null disables the
  /// long-press bar, double-tap, and reaction pills.
  final ReactCallback? onReact;

  /// Relay my typing presence (true while composing, false when stopped). Null
  /// disables sending typing frames.
  final void Function(bool typing)? onTyping;

  /// Tapped a received/sent media tile to open it full-screen.
  final OpenAttachmentCallback? onOpenAttachment;

  String get roomId => room.roomId;
  String get contactDisplayName => room.displayName(selfUsername);

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _emojiOverlay = OverlayPortalController();
  final _emojiLink = LayerLink();
  final _scrollController = ScrollController();

  /// Distance (in logical px) from the bottom that still counts as "at bottom".
  static const _stickThreshold = 120.0;
  bool _atBottom = true;
  int _prevMessageCount = 0;

  /// Media picked but not yet sent, shown as a tray above the composer. Send
  /// flushes these (with the composer text as the last item's caption).
  final List<StagedAttachment> _staged = [];

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
    SchedulerBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding drops the socket and freezes timers; clear typing so a
    // stale `_typingActive` flag can't suppress the next `true` on resume.
    if (state != AppLifecycleState.resumed) _stopTyping();
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

  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _typingStop?.cancel();
    _typingHeartbeat?.cancel();
    // Leaving the room while composing: tell the partner we stopped.
    if (_typingActive) widget.onTyping?.call(false);
    super.dispose();
  }

  void _toggleEmojiPicker() {
    if (_emojiOverlay.isShowing) {
      _emojiOverlay.hide();
    } else {
      _emojiOverlay.show();
    }
    setState(() {});
  }

  void _handleSubmit(String value) {
    final text = value.trim();
    // Staged media takes the composer text as a caption (on the last item) and
    // flushes through onSendMedia. An empty caption is fine — just send the
    // media. Text-only sends fall through to onSend below.
    if (_staged.isNotEmpty) {
      final items = List<StagedAttachment>.of(_staged);
      widget.onSendMedia?.call(items, text);
      setState(() => _staged.clear());
      _controller.clear();
      _stopTyping();
      return;
    }
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    _stopTyping();
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

  /// Long-press a bubble → floating quick-reaction bar anchored at the press,
  /// with a "+" to open the full picker.
  void _showReactionBar(Offset globalPos, Msg m) {
    if (widget.onReact == null) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ReactionBarOverlay(
        anchor: globalPos,
        selected: m.reactions[widget.selfUsername],
        onPick: (emoji) {
          entry.remove();
          _react(m, emoji);
        },
        onMore: () {
          entry.remove();
          _openReactionPicker(m);
        },
        onDismiss: entry.remove,
      ),
    );
    overlay.insert(entry);
  }

  Future<void> _openReactionPicker(Msg m) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: TwilightColors.bgSurface,
      builder: (ctx) => SizedBox(
        height: 320,
        child: EmojiPicker(
          onEmojiSelected: (category, emoji) {
            Navigator.pop(ctx);
            _react(m, emoji.emoji);
          },
          config: const Config(
            height: 320,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: TwilightColors.bgSurface,
              columns: 7,
              emojiSizeMax: 32,
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: TwilightColors.bgSurface,
              indicatorColor: TwilightColors.accentUser,
              iconColor: TwilightColors.textMuted,
              iconColorSelected: TwilightColors.accentUser,
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: TwilightColors.bgSurface,
              buttonColor: TwilightColors.bgSurfaceAlt,
              buttonIconColor: TwilightColors.accentUser,
            ),
            searchViewConfig: SearchViewConfig(
              backgroundColor: TwilightColors.bgSurface,
              buttonIconColor: TwilightColors.accentUser,
            ),
          ),
        ),
      ),
    );
  }

  void _submitFromIntent() {
    _handleSubmit(_controller.text);
  }

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: widget.room.name);
    final newName = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          key: const Key('rename-dialog-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Chat name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('rename-dialog-save'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName == null) return;
    widget.onRename?.call(newName);
  }

  Color _senderColor(String username) {
    if (username == widget.selfUsername) return TwilightColors.accentUser;
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

    // React to new messages: if I sent the newest, or I was already at the
    // bottom, animate down.
    if (messages.length > _prevMessageCount) {
      final newest = messages.fold<Msg?>(
        null,
        (acc, m) => acc == null || m.ts.isAfter(acc.ts) ? m : acc,
      );
      final mine = newest?.from == me;
      if (mine || _atBottom) {
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => _animateToBottom(),
        );
      }
    }
    _prevMessageCount = messages.length;

    final sorted = [...messages]..sort((a, b) => a.ts.compareTo(b.ts));
    final status = _statusModel(sorted, me);
    final items = _itemize(sorted).reversed.toList();
    // The list is reversed, so index 0 is the visual bottom. The typing row
    // lives there permanently (collapsed to zero height when idle) and animates
    // its height in/out — keeping it in the list avoids an insert/remove that
    // would shift every index and make the messages above jump.
    final partnerTyping = ref.watch(typingProvider(widget.roomId));
    items.insert(0, const _TypingItem());
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 8,
        title: ChannelSwitcher(
          selfUsername: widget.selfUsername,
          onNewChannel: widget.onNewChannel,
        ),
        actions: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _E2ESeal(),
          ),
          if (widget.onRename != null)
            PopupMenuButton<String>(
              key: const Key('room-menu-button'),
              icon: const Icon(
                Icons.more_vert,
                color: TwilightColors.textMuted,
              ),
              onSelected: (value) {
                if (value == 'rename' && widget.onRename != null) {
                  _showRenameDialog();
                }
              },
              itemBuilder: (_) => [
                if (widget.onRename != null)
                  const PopupMenuItem<String>(
                    key: Key('room-menu-rename'),
                    value: 'rename',
                    child: Text('Rename chat'),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final item = items[i];
                    // Stable per-row key: without it, inserting/removing the
                    // typing row shifts every index and ListView reuses
                    // elements by position, rebuilding all visible bubbles
                    // (a visible flash). Keying lets Flutter see the messages
                    // just moved one slot and mount only the new row.
                    final (Key key, Widget child) = switch (item) {
                      _BubbleItem(:final msg) => (
                        ValueKey('msg-${msg.id}'),
                        _bubble(
                          msg,
                          me,
                          status.inBubble[msg.id],
                          status.failedRun[msg.id],
                        ),
                      ),
                      _DayItem(:final day) => (
                        ValueKey('day-${day.toIso8601String()}'),
                        _daySeparator(day),
                      ),
                      _GapItem(:final time) => (
                        ValueKey('gap-${time.toIso8601String()}'),
                        _gapHeader(time),
                      ),
                      _TypingItem() => (
                        const ValueKey('typing'),
                        _TypingBubble(active: partnerTyping),
                      ),
                    };
                    return KeyedSubtree(key: key, child: child);
                  },
                ),
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
                        backgroundColor: TwilightColors.bgSurface,
                        foregroundColor: TwilightColors.accentUser,
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
          _composer(),
        ],
      ),
    );
  }

  static const _emojiTapGroup = 'llove.emoji';

  Widget _emojiPanel() {
    return TapRegion(
      groupId: _emojiTapGroup,
      onTapOutside: (_) {
        if (_emojiOverlay.isShowing) {
          _emojiOverlay.hide();
          setState(() {});
        }
      },
      child: SizedBox(
        key: const Key('emoji-panel'),
        width: 340,
        height: 320,
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(12),
          color: TwilightColors.bgSurface,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: EmojiPicker(
              textEditingController: _controller,
              config: Config(
                height: 320,
                emojiViewConfig: EmojiViewConfig(
                  backgroundColor: TwilightColors.bgSurface,
                  columns: 7,
                  emojiSizeMax: 32,
                ),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: TwilightColors.bgSurface,
                  indicatorColor: TwilightColors.accentUser,
                  iconColor: TwilightColors.textMuted,
                  iconColorSelected: TwilightColors.accentUser,
                ),
                bottomActionBarConfig: BottomActionBarConfig(
                  backgroundColor: TwilightColors.bgSurface,
                  buttonColor: TwilightColors.bgSurfaceAlt,
                  buttonIconColor: TwilightColors.accentUser,
                ),
                searchViewConfig: SearchViewConfig(
                  backgroundColor: TwilightColors.bgSurface,
                  buttonIconColor: TwilightColors.accentUser,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(Msg m, String me, _Marker? marker, List<String>? failedIds) {
    final mine = m.from == me;
    // The sent/sending marker (if any) is drawn inside the bubble itself.
    Widget content = _bubbleContent(m, me, marker);
    // Long-press → quick-reaction bar; double-tap → default reaction. Wraps
    // both text and media bubbles; the media bubble's own tap-to-open still
    // wins for a plain tap (deferToChild).
    if (widget.onReact != null) {
      content = GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onLongPressStart: (d) => _showReactionBar(d.globalPosition, m),
        onDoubleTap: () => _react(m, _quickReactions.first),
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
          const Padding(
            padding: EdgeInsets.only(right: 16, top: 2, bottom: 2),
            child: Text(
              'failed · tap to retry',
              style: TextStyle(color: TwilightColors.warningTone, fontSize: 11),
            ),
          ),
        ],
      );
    }

    if (m.reactions.isEmpty) return result;
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [result, _reactionPills(m, me)],
    );
  }

  /// Aggregated reaction pills under a bubble (emoji → count). Mine is
  /// highlighted; tapping a pill toggles my reaction to that emoji.
  Widget _reactionPills(Msg m, String me) {
    final counts = <String, int>{};
    for (final e in m.reactions.values) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final mineEmoji = m.reactions[me];
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
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

  /// Heart (sent) or clock (sending) tucked into a bubble's bottom-right
  /// corner, Telegram style.
  static Widget _markerWidget(_Marker marker) {
    return switch (marker) {
      _Marker.sent => _heart(TwilightColors.accentUser, key: 'status-heart'),
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
            Positioned(left: 0, child: _heart(TwilightColors.accentUserSoft)),
            Positioned(left: 6, child: _heart(TwilightColors.accentUser)),
          ],
        ),
      ),
      _Marker.sending => const Icon(
        Icons.schedule,
        key: Key('status-clock'),
        size: 12,
        color: TwilightColors.textMuted,
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
    if (m.attachment != null) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: _MediaBubble(
            msg: m,
            isMe: mine,
            onOpen: () => widget.onOpenAttachment?.call(m.attachment!),
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
    if (_isEmojiOnly(m.body)) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
          child: Text(
            m.body.trim(),
            style: const TextStyle(fontSize: 48, height: 1.1),
          ),
        ),
      );
    }
    final bubbleColor = mine
        ? TwilightColors.bubbleUserBg
        : TwilightColors.bubblePartnerBg;
    const bubbleBorder = TwilightColors.borderSoft;
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: bubbleBorder),
            ),
            child: _bubbleBody(m, mine, marker),
          ),
        ],
      ),
    );
  }

  Widget _bubbleBody(Msg m, bool mine, _Marker? marker) {
    final text = Text(
      m.body,
      style: TextStyle(
        color: mine
            ? TwilightColors.bubbleUserText
            : TwilightColors.textPrimary,
        fontSize: 16,
      ),
    );
    // Every bubble carries an hh:mm timestamp bottom-right; my bubbles add the
    // sent/sending marker just to the right of the time.
    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatHm(m.ts.toLocal()),
          style: TextStyle(
            fontSize: 10,
            color: mine
                ? TwilightColors.bubbleUserText.withValues(alpha: 0.55)
                : TwilightColors.textMuted,
          ),
        ),
        if (marker != null) ...[
          const SizedBox(width: 4),
          _markerWidget(marker),
        ],
      ],
    );
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

  Widget _daySeparator(DateTime day) {
    return Padding(
      key: ValueKey('day-${day.toIso8601String()}'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Container(height: 1, color: TwilightColors.borderSoft),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _formatDaySeparator(day),
              style: const TextStyle(
                color: TwilightColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Container(height: 1, color: TwilightColors.borderSoft),
          ),
        ],
      ),
    );
  }

  Widget _gapHeader(DateTime t) {
    return Padding(
      key: ValueKey('gap-${t.toIso8601String()}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Text(
          _formatGapHeader(t),
          style: const TextStyle(color: TwilightColors.textMuted, fontSize: 11),
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

  /// True when every grapheme in the message is in an emoji-ish codepoint
  /// range or is whitespace. Conservative: cap at 8 runes so a pasted wall
  /// of emoji still renders as a normal bubble.
  static bool _isEmojiOnly(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final runes = trimmed.runes.toList();
    if (runes.length > 8) return false;
    for (final r in runes) {
      final emoji =
          (r >= 0x2600 && r <= 0x27BF) ||
          (r >= 0x1F300 && r <= 0x1F6FF) ||
          (r >= 0x1F900 && r <= 0x1F9FF) ||
          (r >= 0x1FA70 && r <= 0x1FAFF) ||
          (r >= 0x1F1E6 && r <= 0x1F1FF) ||
          (r >= 0x1F3FB && r <= 0x1F3FF) ||
          r == 0x200D ||
          r == 0xFE0F;
      final ws = r == 0x20 || r == 0x0A || r == 0x09;
      if (!emoji && !ws) return false;
    }
    return true;
  }

  Widget _composer() {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
          const _SendIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, control: true):
          const _SendIntent(),
    };
    return TapRegion(
      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
      child: Container(
        color: TwilightColors.bgSurface,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_staged.isNotEmpty) _stagingTray(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (widget.onPickMedia != null)
                  IconButton(
                    key: const Key('composer-attach'),
                    onPressed: _pickMedia,
                    icon: const Icon(
                      Icons.add,
                      color: TwilightColors.textMuted,
                    ),
                    tooltip: 'Attach a photo or video',
                  ),
                CompositedTransformTarget(
                  link: _emojiLink,
                  child: OverlayPortal(
                    controller: _emojiOverlay,
                    overlayChildBuilder: (_) => Positioned(
                      width: 340,
                      child: CompositedTransformFollower(
                        link: _emojiLink,
                        targetAnchor: Alignment.topLeft,
                        followerAnchor: Alignment.bottomLeft,
                        offset: const Offset(0, -8),
                        child: _emojiPanel(),
                      ),
                    ),
                    child: TapRegion(
                      groupId: _emojiTapGroup,
                      child: IconButton(
                        key: const Key('emoji-toggle'),
                        onPressed: _toggleEmojiPicker,
                        icon: Icon(
                          _emojiOverlay.isShowing
                              ? Icons.keyboard_alt_outlined
                              : Icons.emoji_emotions_outlined,
                          color: TwilightColors.textMuted,
                        ),
                        tooltip: _emojiOverlay.isShowing
                            ? 'Close emoji picker'
                            : 'Emoji',
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Shortcuts(
                    shortcuts: shortcuts,
                    child: Actions(
                      actions: {
                        _SendIntent: CallbackAction<_SendIntent>(
                          onInvoke: (_) {
                            _submitFromIntent();
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        key: const Key('composer'),
                        controller: _controller,
                        onChanged: _onComposerChanged,
                        minLines: 1,
                        maxLines: 8,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText:
                              'Message ${widget.contactDisplayName}'
                              '   ·   ⌘↵ to send',
                          filled: true,
                          fillColor: TwilightColors.bgSurfaceAlt,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: () => _handleSubmit(_controller.text),
                  icon: const Icon(
                    Icons.send,
                    color: TwilightColors.accentUser,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Horizontal strip of staged media above the composer. Each chip shows a
  /// preview (image bytes, or a play badge for video) with a remove button.
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

/// The partner's live "typing…" bubble, rendered in the conversation flow at
/// the bottom of the list (partner side, like an incoming message). Three dots
/// rise and fade in a staggered wave. The row is always present but collapses
/// to zero height when [active] is false; [AnimatedSize] grows/shrinks it so
/// the messages above slide rather than jump.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble({required this.active});

  final bool active;

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // Created eagerly here (not lazily) so dispose() never instantiates a
    // ticker during teardown when the bubble was never active.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _TypingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only spend animation cycles while the bubble is actually showing.
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      // Grow upward from the bottom so the row expands into the gap above it.
      alignment: Alignment.bottomLeft,
      child: widget.active
          ? Align(
              key: const Key('typing-indicator'),
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: TwilightColors.bubblePartnerBg,
                  // A softened bottom-left corner gives the bubble a tail.
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                    bottomLeft: Radius.circular(5),
                  ),
                  border: Border.all(color: TwilightColors.borderSoft),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = 0; i < 3; i++) _dot(i)],
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _dot(int index) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        // sin(phase·π) is a smooth 0→1→0 hump; staggering the phase per dot
        // makes the three rise in a wave.
        final phase = (_c.value + index * 0.18) % 1.0;
        final lift = math.sin(phase * math.pi).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Transform.translate(
            offset: Offset(0, -4 * lift),
            child: Opacity(
              opacity: 0.4 + 0.6 * lift,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: TwilightColors.accentSage,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      },
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
              ? TwilightColors.accentUser.withValues(alpha: 0.18)
              : TwilightColors.bgSurfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: mine ? TwilightColors.accentUser : TwilightColors.borderSoft,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 14)),
            if (count > 1) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 12,
                  color: TwilightColors.textMuted,
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
    required this.onPick,
    required this.onMore,
    required this.onDismiss,
  });
  final Offset anchor;
  final String? selected;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;
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
    const barWidth = 296.0;
    const barHeight = 48.0;
    var left = (widget.anchor.dx - barWidth / 2).clamp(
      8.0,
      size.width - barWidth - 8.0,
    );
    // Prefer sitting just above the press point; if that would clip the top,
    // flip below it.
    var top = widget.anchor.dy - barHeight - 12;
    if (top < padding.top + 8) top = widget.anchor.dy + 12;
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
            alignment: Alignment.bottomCenter,
            child: FadeTransition(opacity: _c, child: _bar()),
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
      color: TwilightColors.bgSurface,
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
              ? TwilightColors.accentUser.withValues(alpha: 0.18)
              : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 24)),
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
        child: const Icon(Icons.add, color: TwilightColors.textMuted),
      ),
    );
  }
}

/// A single staged-media chip in the composer tray: a square preview with a
/// remove (×) button. Images render their bytes inline; videos show a play
/// badge over a neutral fill (no decode needed for the tray).
class _StagedChip extends StatelessWidget {
  const _StagedChip({required this.item, required this.onRemove});
  final StagedAttachment item;
  final VoidCallback onRemove;

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
            child: SizedBox(
              width: 64,
              height: 64,
              child: item.isVideo
                  ? Container(
                      color: TwilightColors.bgSurfaceAlt,
                      child: const Center(child: _PlayBadge()),
                    )
                  : Image.memory(item.bytes, fit: BoxFit.cover),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
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
}

class _MediaBubble extends StatelessWidget {
  const _MediaBubble({
    required this.msg,
    required this.isMe,
    required this.onOpen,
  });
  final Msg msg;
  final bool isMe;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final d = msg.attachment!;
    final aspect = (d.width > 0 && d.height > 0) ? d.width / d.height : 4 / 3;
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isMe
              ? TwilightColors.bubbleUserBg
              : TwilightColors.bubblePartnerBg,
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
                    _ThumbImage(thumbB64: d.thumbB64),
                    if (d.isVideo) const Center(child: _PlayBadge()),
                    if (msg.sendStatus == SendStatus.sending)
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
                        ? TwilightColors.bubbleUserText
                        : TwilightColors.textPrimary,
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
          );
        }
        return Container(color: TwilightColors.bgSurfaceAlt);
      },
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();
  @override
  Widget build(BuildContext context) => Container(
    width: 52,
    height: 52,
    decoration: BoxDecoration(
      color: const Color(0x6B140C12),
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xBFFFFFFF), width: 1.5),
    ),
    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
  );
}

class _E2ESeal extends StatelessWidget {
  const _E2ESeal();
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(
          Icons.lock_outline,
          size: 14,
          color: TwilightColors.accentSage,
          semanticLabel: 'End-to-end encrypted',
        ),
        SizedBox(width: 8),
        Text(
          'END-TO-END',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            letterSpacing: 2.2,
            fontWeight: FontWeight.w500,
            color: TwilightColors.textMuted,
          ),
        ),
      ],
    );
  }
}
