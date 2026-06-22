import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_download.dart';
import '../attachment/staged_attachment.dart';
import '../attachment/thumbnail.dart';
import '../identity/providers.dart';
import '../inbox/channel_switcher.dart';
import '../wallpaper/wallpaper_background.dart';
import '../wallpaper/wallpaper_controller.dart';
import '../wallpaper/wallpaper_screen.dart';
import '../inbox/room.dart';
import '../theme/love_toast.dart';
import '../theme/twilight.dart';
import '../wire/live_connection.dart';
import '../wire/message.dart';
import 'link_preview.dart';
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
    this.onDelete,
    this.onCancelSend,
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

  /// Unsend a confirmed message for everyone, by message id. Null hides the
  /// Delete action on confirmed messages.
  final void Function(String targetId)? onDelete;

  /// Cancel an unconfirmed (still sending / failed) outgoing send, by its
  /// clientMsgId: drops the optimistic bubble and its outbox row. Null hides
  /// the Delete action on unconfirmed messages.
  final void Function(String clientMsgId)? onCancelSend;

  /// Relay my typing presence (true while composing, false when stopped). Null
  /// disables sending typing frames.
  final void Function(bool typing)? onTyping;

  /// Tapped a received/sent media tile to open it full-screen.
  final OpenAttachmentCallback? onOpenAttachment;

  String get roomId => room.roomId;

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// Measures the floating composer so the message list can reserve matching
  /// bottom padding (the list scrolls *under* the frosted bar, so its newest
  /// row must clear the glass). Tracked in state and re-measured each frame;
  /// the bar's height changes with multiline growth and the staging tray.
  final _composerKey = GlobalKey();
  double _composerHeight = 0;

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

  void _measureComposer() {
    if (!mounted) return;
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    final h = box?.size.height;
    if (h != null && (h - _composerHeight).abs() > 0.5) {
      setState(() => _composerHeight = h);
    }
  }

  /// Distance (in logical px) from the bottom that still counts as "at bottom".
  static const _stickThreshold = 120.0;
  bool _atBottom = true;
  int _prevMessageCount = 0;

  /// Guards against stacking multiple post-frame scroll callbacks when a send
  /// triggers several rebuilds in quick succession (optimistic add → echo
  /// reconcile), which is what made the auto-scroll stutter.
  bool _scrollScheduled = false;

  /// Media picked but not yet sent, shown as a tray above the composer. Send
  /// flushes these (with the composer text as the last item's caption).
  final List<StagedAttachment> _staged = [];

  /// The live long-press reaction/actions overlay, if one is showing. Tracked
  /// so it can be torn down in [dispose] — otherwise popping the page mid-
  /// display (back-swipe, room switch) leaves the entry mounted against a
  /// disposed state, with its animation controller still ticking.
  OverlayEntry? _reactionEntry;

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
    _dismissReactionBar();
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

  void _handleSubmit(String value) {
    final text = value.trim();
    // Staged media takes the composer text as a caption (on the last item) and
    // flushes through onSendMedia. An empty caption is fine — just send the
    // media. Text-only sends fall through to onSend below.
    if (_staged.isNotEmpty) {
      HapticFeedback.lightImpact();
      final items = List<StagedAttachment>.of(_staged);
      widget.onSendMedia?.call(items, text);
      ref.read(wallpaperDriftProvider.notifier).bump();
      setState(() => _staged.clear());
      _controller.clear();
      _stopTyping();
      return;
    }
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    widget.onSend(text);
    ref.read(wallpaperDriftProvider.notifier).bump();
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

  /// Long-press a bubble → floating context menu anchored at the press: a
  /// quick-reaction bar (when reactions are enabled) plus Copy/Delete actions.
  void _showReactionBar(Offset globalPos, Msg m) {
    final mine = m.from == widget.selfUsername;
    final canCopy = _canCopy(m);
    final delete = _deleteAction(m, mine);
    if (widget.onReact == null && !canCopy && delete == null) return;
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
        onCopy: canCopy
            ? () {
                _dismissReactionBar();
                _copy(m);
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
    final status = _statusModel(sorted, me);
    // Reversed, so index 0 is the visual bottom — i.e. the newest message is
    // the true leading edge, which is what lets a reverse list pin to the
    // bottom on its own. The partner's "typing…" indicator deliberately lives
    // in the app bar (not as a bottom row) so it never reflows this list.
    final items = _itemize(sorted).reversed.toList();
    // Re-measure the floating composer after this frame paints so the list's
    // reserved bottom padding tracks the bar as it grows/shrinks.
    SchedulerBinding.instance.addPostFrameCallback((_) => _measureComposer());
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: const ColorFilter.matrix(_glassSaturation),
              inner: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TwilightColors.bgCanvas.withValues(alpha: 0.62),
                border: Border(
                  bottom: BorderSide(
                    color: TwilightColors.textPrimary.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
        titleSpacing: 8,
        title: ChannelSwitcher(
          selfUsername: widget.selfUsername,
          onNewChannel: widget.onNewChannel,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _TopStatus(roomId: widget.roomId),
          ),
          PopupMenuButton<String>(
            key: const Key('room-menu-button'),
            icon: const Icon(Icons.more_vert, color: TwilightColors.textMuted),
            onSelected: (value) {
              switch (value) {
                case 'wallpaper':
                  Navigator.of(context).push(WallpaperScreen.route());
                case 'rename':
                  if (widget.onRename != null) _showRenameDialog();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                key: Key('room-menu-wallpaper'),
                value: 'wallpaper',
                child: Text('Wallpaper'),
              ),
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
      body: WallpaperBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                // Reserve room for the floating glass composer so the newest
                // message clears it (reverse:true → bottom padding is the
                // visual bottom). Height is measured from the live bar.
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12 + MediaQuery.of(context).padding.top + kToolbarHeight,
                  bottom: _composerHeight + 12,
                ),
                itemCount: items.length,
                // Relocate existing keyed rows by identity when an insert
                // shifts indices, so the delegate reuses them instead of
                // rebuilding the visible list (the receive-time flash).
                findChildIndexCallback: (key) {
                  final value = (key as ValueKey<String>).value;
                  final idx = items.indexWhere((it) => _rowKey(it) == value);
                  return idx < 0 ? null : idx;
                },
                itemBuilder: (_, i) {
                  final item = items[i];
                  final child = switch (item) {
                    _BubbleItem(:final msg) => _bubble(
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
            Positioned(
              right: 16,
              bottom: _composerHeight + 16,
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
            Align(
              alignment: Alignment.bottomCenter,
              child: KeyedSubtree(key: _composerKey, child: _composer()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(Msg m, String me, _Marker? marker, List<String>? failedIds) {
    final mine = m.from == me;
    // The sent/sending marker (if any) is drawn inside the bubble itself.
    Widget content = _bubbleContent(m, me, marker);
    // Long-press → context menu (reactions + Copy/Delete); double-tap →
    // default reaction. Wraps both text and media bubbles; the media bubble's
    // own tap-to-open still wins for a plain tap (deferToChild).
    final canLongPress =
        widget.onReact != null || _canCopy(m) || _deleteAction(m, mine) != null;
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
      children: [result, _reactionPills(m, me, mine)],
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
            marker: marker,
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

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _bubbleBody(Msg m, bool mine, _Marker? marker) {
    final textColor = mine
        ? TwilightColors.bubbleUserText
        : TwilightColors.textPrimary;
    final text = Linkify(
      text: m.body,
      onOpen: (link) => _openUrl(link.url),
      options: const LinkifyOptions(humanize: false, looseUrl: true),
      style: TextStyle(color: textColor, fontSize: 16),
      linkStyle: TextStyle(
        color: textColor,
        decoration: TextDecoration.underline,
        decorationColor: textColor.withValues(alpha: 0.6),
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
      // Frosted-glass bar: the message list scrolls underneath and is blurred
      // through a translucent canvas tint, so the composer floats instead of
      // sitting on a solid slab. ClipRect bounds the backdrop blur to the bar.
      child: ClipRect(
        child: BackdropFilter(
          // Apple-style material: blur the messages behind, then lift their
          // saturation back up (ColorFilter implements ImageFilter, so
          // compose() chains it over the blur) so the glass stays luminous.
          filter: ImageFilter.compose(
            outer: const ColorFilter.matrix(_glassSaturation),
            inner: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: TwilightColors.bgCanvas.withValues(alpha: 0.72),
              // Hairline at the top edge, like iMessage/Telegram, so the glass
              // boundary reads crisply against messages passing underneath.
              border: Border(
                top: BorderSide(
                  color: TwilightColors.textPrimary.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_staged.isNotEmpty) _stagingTray(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // The pill: one rounded surface holding the attach action
                        // (inside-left, bottom-pinned) and the text field. Bottom
                        // alignment keeps the attach glyph on the last line as the
                        // field grows, instead of drifting to the vertical center.
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: TwilightColors.bgSurfaceAlt,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (widget.onPickMedia != null)
                                  IconButton(
                                    key: const Key('composer-attach'),
                                    onPressed: _pickMedia,
                                    icon: const Icon(
                                      Icons.attach_file,
                                      color: TwilightColors.textMuted,
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
                                        onChanged: _onComposerChanged,
                                        minLines: 1,
                                        maxLines: 8,
                                        keyboardType: TextInputType.multiline,
                                        textInputAction:
                                            TextInputAction.newline,
                                        decoration: InputDecoration(
                                          isDense: true,
                                          hintText: 'Message',
                                          hintStyle: const TextStyle(
                                            color: TwilightColors.textMuted,
                                          ),
                                          border: InputBorder.none,
                                          // Lead padding only when the attach button
                                          // isn't there to provide it.
                                          contentPadding: EdgeInsets.fromLTRB(
                                            widget.onPickMedia != null ? 0 : 16,
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
                        const SizedBox(width: 8),
                        _trailingButton(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Single trailing control that morphs between an idle mic affordance and
  /// the active send button, Telegram-style. A cross-fade (not a scale) keeps
  /// whichever child is showing at full layout size, so it stays tappable the
  /// frame it appears.
  Widget _trailingButton() {
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

  /// Filled circular send.
  Widget _sendButton() {
    return Material(
      key: const Key('composer-send'),
      color: TwilightColors.accentUser,
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

  /// Idle-state mic affordance. Voice notes aren't implemented yet, so the tap
  /// just signals that they're coming rather than leaving a dead control.
  Widget _micButton() {
    return IconButton(
      key: const Key('composer-mic'),
      onPressed: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice messages are coming soon'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      iconSize: 24,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      icon: const Icon(Icons.mic, color: TwilightColors.textMuted),
      tooltip: 'Voice message (coming soon)',
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

/// Top-bar status for the conversation: the partner's "Typing…" with gently
/// pulsing dots while they compose, and nothing when idle. Living in the app
/// bar (not as a list row) keeps the partner's typing state from reflowing the
/// message list — which otherwise nudged the list on send.
class _TopStatus extends ConsumerWidget {
  const _TopStatus({required this.roomId});
  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typing = ref.watch(typingProvider(roomId));
    if (!typing) return const SizedBox.shrink();
    return Row(
      key: const Key('typing-indicator'),
      mainAxisSize: MainAxisSize.min,
      children: const [
        Text(
          'Typing',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            letterSpacing: 0.4,
            fontWeight: FontWeight.w500,
            color: TwilightColors.accentSage,
          ),
        ),
        SizedBox(width: 6),
        _PulsingDots(),
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
                    decoration: const BoxDecoration(
                      color: TwilightColors.accentSage,
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
          color: TwilightColors.bgSurfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: const Border(
            left: BorderSide(color: TwilightColors.accentSage, width: 3),
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
                      style: const TextStyle(
                        fontSize: 10,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w600,
                        color: TwilightColors.accentSage,
                      ),
                    ),
                  if (preview.title != null && preview.title!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        preview.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: TwilightColors.textPrimary,
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
                        style: const TextStyle(
                          fontSize: 12,
                          color: TwilightColors.textMuted,
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
    required this.showReactions,
    required this.onPick,
    required this.onMore,
    required this.onCopy,
    required this.onDelete,
    required this.onDismiss,
  });
  final Offset anchor;
  final String? selected;
  final bool showReactions;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;
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
        (widget.onCopy != null ? 1 : 0) + (widget.onDelete != null ? 1 : 0);
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

  Widget _actions() {
    return Material(
      key: const Key('message-actions'),
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      color: TwilightColors.bgSurface,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onCopy != null)
              _actionItem(
                key: 'action-copy',
                icon: Icons.copy_outlined,
                label: 'Copy',
                onTap: widget.onCopy!,
              ),
            if (widget.onDelete != null)
              _actionItem(
                key: 'action-delete',
                icon: Icons.delete_outline,
                label: 'Delete',
                color: TwilightColors.warningTone,
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
    final c = color ?? TwilightColors.textPrimary;
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
              ? TwilightColors.accentUser.withValues(alpha: 0.18)
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
        child: const Icon(Icons.add, color: TwilightColors.textMuted),
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
              : Container(color: TwilightColors.bgSurfaceAlt),
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
            _ConversationPageState._markerWidget(marker!),
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
        return Container(color: TwilightColors.bgSurfaceAlt);
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
