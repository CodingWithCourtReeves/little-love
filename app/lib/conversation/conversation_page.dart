import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/providers.dart';
import '../inbox/room.dart';
import '../theme/twilight.dart';
import '../wire/message.dart';
import 'message_store.dart';

typedef SendCallback = void Function(String text);
typedef RenameCallback = void Function(String newName);
typedef LeaveCallback = void Function();

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
    this.onLeave,
  });

  final Room room;
  final String selfUsername;
  final SendCallback onSend;
  final RenameCallback? onRename;
  final LeaveCallback? onLeave;

  String get roomId => room.roomId;
  String get contactDisplayName => room.displayName(selfUsername);

  @override
  ConsumerState<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends ConsumerState<ConversationPage> {
  final _controller = TextEditingController();
  final _emojiOverlay = OverlayPortalController();
  final _emojiLink = LayerLink();
  final _scrollController = ScrollController();

  /// Distance (in logical px) from the bottom that still counts as "at bottom".
  static const _stickThreshold = 120.0;
  bool _atBottom = true;
  int _prevMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    SchedulerBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
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
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
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

  Future<void> _showLeaveDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave chat?'),
        content: const Text(
          'Messages already sent stay encrypted on other devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('leave-dialog-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    widget.onLeave?.call();
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
    final items = _itemize(sorted).reversed.toList();
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 8,
        title: Row(
          children: [
            _PeerAvatar(label: widget.contactDisplayName),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    widget.contactDisplayName,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      _Dot(color: TwilightColors.accentFamiliar),
                      SizedBox(width: 6),
                      Text(
                        'paired',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          letterSpacing: 0.6,
                          color: TwilightColors.accentFamiliar,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _E2ESeal(),
          ),
          if (widget.onRename != null || widget.onLeave != null)
            PopupMenuButton<String>(
              key: const Key('room-menu-button'),
              icon: const Icon(
                Icons.more_vert,
                color: TwilightColors.textMuted,
              ),
              onSelected: (value) {
                if (value == 'rename' && widget.onRename != null) {
                  _showRenameDialog();
                } else if (value == 'leave' && widget.onLeave != null) {
                  _showLeaveDialog();
                }
              },
              itemBuilder: (_) => [
                if (widget.onRename != null)
                  const PopupMenuItem<String>(
                    key: Key('room-menu-rename'),
                    value: 'rename',
                    child: Text('Rename chat'),
                  ),
                if (widget.onLeave != null)
                  const PopupMenuItem<String>(
                    key: Key('room-menu-leave'),
                    value: 'leave',
                    child: Text('Leave chat'),
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
                    return switch (item) {
                      _BubbleItem(:final msg) => _bubble(msg, me),
                      _DayItem(:final day) => _daySeparator(day),
                      _GapItem(:final time) => _gapHeader(time),
                    };
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

  Widget _bubble(Msg m, String me) {
    final mine = m.from == me;
    final tip = _formatFullDateTime(m.ts.toLocal());
    final showSenderLabel = !mine && widget.room.members.length >= 3;
    if (_isEmojiOnly(m.body)) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 400),
          preferBelow: false,
          verticalOffset: 18,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
            child: Text(
              m.body.trim(),
              style: const TextStyle(fontSize: 48, height: 1.1),
            ),
          ),
        ),
      );
    }
    // Resolve whether this message's sender is a familiar (bot) in this room.
    final senderIsBot = widget.room.memberByUsername(m.from)?.isBot ?? false;
    final bubbleColor = mine
        ? TwilightColors.bubbleUserBg
        : (senderIsBot
            ? TwilightColors.bubbleFamiliarBg
            : TwilightColors.bubblePartnerBg);
    final bubbleBorder =
        senderIsBot && !mine
            ? TwilightColors.bubbleFamiliarBorder
            : TwilightColors.borderSoft;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        preferBelow: false,
        verticalOffset: 14,
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
              constraints: const BoxConstraints(maxWidth: 480),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: bubbleBorder),
              ),
              child: Text(
                m.body,
                style: TextStyle(
                  color: mine
                      ? TwilightColors.bubbleUserText
                      : TwilightColors.textPrimary,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
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

  static String _formatFullDateTime(DateTime t) {
    return '${_formatDaySeparator(_dateOnly(t))} at ${_formatTime(t)}';
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
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
              icon: const Icon(Icons.send, color: TwilightColors.accentUser),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerAvatar extends StatelessWidget {
  const _PeerAvatar({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    return Container(
      width: 36,
      height: 36,
      decoration: const BoxDecoration(
        color: TwilightColors.accentPartner,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: Color(0xFFFFFAFB),
          fontFamily: 'Inter',
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
          color: TwilightColors.accentFamiliar,
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
