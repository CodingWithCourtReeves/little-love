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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

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
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: context.palette.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
