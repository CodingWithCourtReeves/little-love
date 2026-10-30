import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// The colors a [ReplyQuote] uses on one side's bubble.
typedef ReplyQuoteColors = ({Color inset, Color bar, Color name, Color text});

/// Telegram-style reply quote at the top *inside* a bubble (text, media and
/// voice alike), #88: a light inset that reads as part of the bubble, a 3px
/// accent bar, the original author in the accent color, and up to two lines of
/// the quoted text. Tapping it calls [onTap] (the page jumps to the original).
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.author,
    required this.preview,
    required this.icon,
    required this.onUserBubble,
    required this.onTap,
  });

  /// Who wrote the quoted message ("You", or the partner's name).
  final String author;

  /// The quoted text, or the media label ("Photo", "Voice message · hi").
  final String preview;

  /// Kind glyph for a quoted photo, video, voice memo or file; null for text.
  final IconData? icon;

  /// True inside my own (accent-filled) bubble, false inside the partner's.
  final bool onUserBubble;

  final VoidCallback onTap;

  /// The quote's colors for one side. On my bubble the inset is
  /// [AppPalette.replyInsetOnUser] and the author uses the darker
  /// [AppPalette.replyNameOnUser], because the plain accent (or the old sage)
  /// falls short of 4.5:1 at 13px there. On the partner's bubble the inset is
  /// an accent tint and the author the accent itself.
  static ReplyQuoteColors colorsFor(
    AppPalette p, {
    required bool onUserBubble,
  }) => onUserBubble
      ? (
          inset: p.replyInsetOnUser,
          bar: p.accentUser,
          name: p.replyNameOnUser,
          text: p.bubbleUserText.withValues(alpha: 0.8),
        )
      : (
          inset: p.accentUser.withValues(alpha: 0.08),
          bar: p.accentUser,
          name: p.accentUser,
          text: p.textMuted,
        );

  @override
  Widget build(BuildContext context) {
    final c = colorsFor(context.palette, onUserBubble: onUserBubble);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.inset,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: c.bar, width: 3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.name,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 13, color: c.text),
                  ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    preview,
                    key: const Key('reply-quote-text'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: c.text),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
