import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/twilight.dart';
import 'conversation_list_item.dart';
import 'inbox_state.dart';

/// Drawer contents at <600px widths (spec §6.1). Tap an entry to select +
/// dismiss the drawer.
class DrawerContent extends ConsumerWidget {
  const DrawerContent({super.key, required this.username});

  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    final theme = Theme.of(context);
    return Container(
      color: TwilightColors.bgSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'COUPLES',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: TwilightColors.textMuted,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ...inbox.rooms.map(
              (r) => ConversationListItem(
                key: Key('drawer-room-${r.roomId}'),
                label: r.peerUsername,
                selected: inbox.selectedRoomId == r.roomId,
                onTap: () {
                  ref.read(inboxStateProvider.notifier).select(r.roomId);
                  Navigator.of(context).pop();
                },
              ),
            ),
            const Spacer(),
            Container(height: 1, color: TwilightColors.borderSoft),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '@$username',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: TwilightColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
