import 'package:flutter/material.dart';

import '../theme/twilight.dart';

/// Single row in the sidebar / drawer. The whole row is the tap target;
/// minimum 44x44 logical px per spec §6.4.
class ConversationListItem extends StatelessWidget {
  const ConversationListItem({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.unread = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Whether this room has unread incoming messages — draws a trailing dot.
  final bool unread;

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
            color: selected ? TwilightColors.bgSurfaceAlt : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected
                    ? TwilightColors.accentUser
                    : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: TwilightColors.textPrimary,
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
                  decoration: const BoxDecoration(
                    color: TwilightColors.accentUser,
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
