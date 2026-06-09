import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/hearth.dart';
import 'wire/message.dart';

typedef SendCallback = void Function(String text);

class _SendIntent extends Intent {
  const _SendIntent();
}

class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.meUsername,
    required this.contactDisplayName,
    required this.messages,
    required this.onSend,
  });

  final String meUsername;
  final String contactDisplayName;
  final List<Msg> messages;
  final SendCallback onSend;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _controller = TextEditingController();
  final _emojiOverlay = OverlayPortalController();
  final _emojiLink = LayerLink();

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.messages]
      ..sort((a, b) => a.ts.compareTo(b.ts));
    return Scaffold(
      backgroundColor: HearthColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: HearthColors.bgSurface,
        elevation: 0,
        title: Text(
          widget.contactDisplayName,
          style: const TextStyle(color: HearthColors.textPrimary),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: sorted.length,
              itemBuilder: (_, i) => _bubble(sorted[i]),
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
          color: HearthColors.bgSurface,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: EmojiPicker(
              textEditingController: _controller,
              config: Config(
                height: 320,
                emojiViewConfig: EmojiViewConfig(
                  backgroundColor: HearthColors.bgSurface,
                  columns: 8,
                ),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: HearthColors.bgSurface,
                  indicatorColor: HearthColors.accentUser,
                  iconColor: HearthColors.textMuted,
                  iconColorSelected: HearthColors.accentUser,
                ),
                bottomActionBarConfig: BottomActionBarConfig(
                  backgroundColor: HearthColors.bgSurface,
                  buttonColor: HearthColors.bgSurfaceAlt,
                  buttonIconColor: HearthColors.accentUser,
                ),
                searchViewConfig: SearchViewConfig(
                  backgroundColor: HearthColors.bgSurface,
                  buttonIconColor: HearthColors.accentUser,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(Msg m) {
    final mine = m.from == widget.meUsername;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: mine ? HearthColors.bubbleUserBg : HearthColors.bubblePartnerBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: HearthColors.borderSoft),
        ),
        child: Text(
          m.body,
          style: TextStyle(
            color: mine ? HearthColors.bubbleUserText : HearthColors.textPrimary,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    // Cmd+Enter on Mac, Ctrl+Enter on Windows/Linux both send.
    // Plain Enter inserts a newline, matching Slack / Discord conventions.
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
          const _SendIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, control: true):
          const _SendIntent(),
    };
    return Container(
      color: HearthColors.bgSurface,
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
                    color: HearthColors.textMuted,
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
                  _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
                    _submitFromIntent();
                    return null;
                  }),
                },
                child: TextField(
                  key: const Key('composer'),
                  controller: _controller,
                  minLines: 1,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'Message ${widget.contactDisplayName}'
                        '   ·   ⌘↵ to send',
                    filled: true,
                    fillColor: HearthColors.bgSurfaceAlt,
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
            icon: const Icon(Icons.send, color: HearthColors.accentUser),
          ),
        ],
      ),
    );
  }
}
