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

/// Persistent sidebar at ≥800px widths (spec §6.1). 240px wide.
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.username});

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
    final familiars = bucket(RoomShape.familiar);

    ConversationListItem item(Room r) => ConversationListItem(
      key: Key('room-${r.roomId}'),
      label: pending.containsKey(r.roomId)
          ? 'Inviting partner…'
          : r.displayName(username),
      selected: inbox.selectedRoomId == r.roomId,
      onTap: () => selectAndMarkRead(ref, r.roomId),
    );

    return Container(
      color: TwilightColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader('PARTNER', theme),
          ...partners.map(item),
          const SizedBox(height: 16),
          _sectionHeader('CHATS', theme),
          ...chats.map(item),
          const SizedBox(height: 16),
          _sectionHeader('FAMILIARS', theme),
          ...familiars.map(item),
          const Spacer(),
          Container(height: 1, color: TwilightColors.borderSoft),
          _footer(theme),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: TwilightColors.textMuted,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    return Consumer(
      builder: (context, ref, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            IconButton(
              key: const Key('sidebar-new-chat'),
              icon: const Icon(Icons.add, color: TwilightColors.textMuted),
              onPressed: () {
                final account = ref.read(accountProvider).asData?.value;
                if (account == null) return;
                ref.read(inboxStateProvider.notifier).deselect();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NewChatScreen(account: account),
                  ),
                );
              },
              tooltip: 'New chat',
            ),
            IconButton(
              key: const Key('sidebar-settings'),
              icon: const Icon(Icons.settings, color: TwilightColors.textMuted),
              onPressed: () {},
              tooltip: 'Settings',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '@$username',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: TwilightColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
