import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// Single row in the sidebar / drawer. The whole row is the tap target;
/// minimum 44x44 logical px per spec §6.4.
class ConversationListItem extends StatelessWidget {
  const ConversationListItem({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.unread = false,
    this.leading,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Whether this room has unread incoming messages — draws a trailing dot.
  final bool unread;

  /// Optional leading widget (the partner's avatar) shown before the label.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? context.palette.bgSurfaceAlt : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected
                    ? context.palette.accentUser
                    : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 12)],
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: context.palette.textPrimary,
                    fontWeight: (selected || unread)
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (unread)
                Container(
                  key: const Key('unread-dot'),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: context.palette.accentUser,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
