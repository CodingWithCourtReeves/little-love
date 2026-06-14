import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/twilight.dart';
import 'conversation_list_item.dart';
import 'inbox_state.dart';
import 'room.dart';

/// Drawer contents at <600px widths (spec §6.1). Tap an entry to select +
/// dismiss the drawer.
class DrawerContent extends ConsumerWidget {
  const DrawerContent({super.key, required this.username});

  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    final theme = Theme.of(context);

    final couples =
        inbox.rooms
            .where((r) => r.shape(username) == RoomShape.couplesOnly)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final familiars =
        inbox.rooms
            .where((r) => r.shape(username) == RoomShape.familiars)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    Widget header(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: TwilightColors.textMuted,
          letterSpacing: 1.2,
        ),
      ),
    );

    Widget item(Room r) => ConversationListItem(
      key: Key('drawer-room-${r.roomId}'),
      label: r.displayName(username),
      selected: inbox.selectedRoomId == r.roomId,
      onTap: () {
        ref.read(inboxStateProvider.notifier).select(r.roomId);
        Navigator.of(context).pop();
      },
    );

    return Container(
      color: TwilightColors.bgSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header('COUPLES'),
            ...couples.map(item),
            const SizedBox(height: 16),
            header('FAMILIARS'),
            ...familiars.map(item),
            const Spacer(),
            Container(height: 1, color: TwilightColors.borderSoft),
            Material(
              color: Colors.transparent,
              child: ListTile(
                key: const Key('drawer-new-chat'),
                leading: const Icon(
                  Icons.add,
                  color: TwilightColors.textMuted,
                ),
                title: const Text('New chat'),
                onTap: () {
                  ref.read(inboxStateProvider.notifier).deselect();
                  Navigator.of(context).pop();
                },
              ),
            ),
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
