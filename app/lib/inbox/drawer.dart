import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/providers.dart';
import '../screens/inbox/new_chat_screen.dart';
import '../theme/twilight.dart';
import 'conversation_list_item.dart';
import 'inbox_state.dart';
import 'pending_invites_provider.dart';
import 'room.dart';
import 'select_room.dart';

/// Drawer contents at <600px widths (spec §6.1). Tap an entry to select +
/// dismiss the drawer.
class DrawerContent extends ConsumerWidget {
  const DrawerContent({super.key, required this.username});

  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    final pending = ref.watch(pendingInvitesProvider);
    final theme = Theme.of(context);

    List<Room> bucket(RoomShape shape) =>
        inbox.rooms.where((r) => r.shape(username) == shape).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final partners = bucket(RoomShape.partner);
    final chats = bucket(RoomShape.chat);

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
      label: pending.containsKey(r.roomId)
          ? 'Inviting partner…'
          : r.displayName(username),
      selected: inbox.selectedRoomId == r.roomId,
      onTap: () {
        selectAndMarkRead(ref, r.roomId);
        Navigator.of(context).pop();
      },
    );

    return Container(
      color: TwilightColors.bgSurface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header('PARTNER'),
            ...partners.map(item),
            const SizedBox(height: 16),
            header('CHATS'),
            ...chats.map(item),
            const Spacer(),
            Container(height: 1, color: TwilightColors.borderSoft),
            Material(
              color: Colors.transparent,
              child: ListTile(
                key: const Key('drawer-new-chat'),
                leading: const Icon(Icons.add, color: TwilightColors.textMuted),
                title: const Text('New chat'),
                onTap: () {
                  final account = ref.read(accountProvider).asData?.value;
                  ref.read(inboxStateProvider.notifier).deselect();
                  Navigator.of(context).pop();
                  if (account == null) return;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => NewChatScreen(account: account),
                    ),
                  );
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
