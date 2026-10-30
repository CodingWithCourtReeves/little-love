import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// The reactions on a message, as one small badge pinned to the bubble's top
/// corner (#79), iMessage-style. Rooms are always exactly two people, so there
/// is no count: each partner's emoji shows, the partner's first and mine on
/// top, slightly overlapped. An accent ring marks the badge when one of them
/// is mine.
///
/// Tapping it ([onTap]) takes my reaction back, or, when only the partner has
/// reacted, matches theirs (decided by the page).
class ReactionBadge extends StatelessWidget {
  const ReactionBadge({
    super.key,
    required this.emojis,
    required this.hasMine,
    required this.onTap,
  });

  /// Partner's reaction first, then mine; one or two entries.
  final List<String> emojis;
  final bool hasMine;
  final VoidCallback onTap;

  /// The badge's height; the page reserves half of it above a reacted bubble.
  static const height = 28.0;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: 'Reactions ${emojis.join(' ')}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: height,
          constraints: const BoxConstraints(minWidth: height),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: palette.bubblePartnerBg,
            borderRadius: BorderRadius.circular(height / 2),
            border: Border.all(
              color: hasMine ? palette.accentUser : palette.borderSoft,
            ),
            boxShadow: [
              BoxShadow(
                color: palette.textPrimary.withValues(alpha: 0.14),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < emojis.length; i++)
                // Each later emoji tucks ~3px under the one before it; the
                // Align shrinks its slot and lets the glyph paint into the gap.
                Align(
                  widthFactor: i == 0 ? 1 : 0.78,
                  alignment: Alignment.centerRight,
                  child: _CenteredEmoji(emojis[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One emoji in a slot exactly 1em square, so it centers on its *ink*.
///
/// Apple Color Emoji, reached through iOS font fallback, lays each emoji out
/// ~1.27em wide with the glyph in the first ~1em and the spare space all on the
/// right, and draws it ~0.06em low. Centering that text box put the glyph ~2px
/// left of center (measured: 7.5px of badge on the left vs 11.5px on the
/// right). So the slot is 1em, the empty tail overflows invisibly, the glyph is
/// lifted 0.06em, and the inherited Material letter spacing (which adds more
/// trailing space) is zeroed. Measured on the CoreText path: centered within
/// 0.25px on both axes for ❤️ 😂 🥺 🔥.
class _CenteredEmoji extends StatelessWidget {
  const _CenteredEmoji(this.emoji);

  final String emoji;

  static const _size = 15.0;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, -_size * 0.06),
      child: SizedBox(
        width: _size,
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          maxWidth: double.infinity,
          child: Text(
            emoji,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
              fontSize: _size,
              height: 1.0,
              letterSpacing: 0,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}
