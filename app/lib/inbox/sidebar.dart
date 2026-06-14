import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../identity/providers.dart';
import '../screens/inbox/new_chat_screen.dart';
import '../theme/twilight.dart';
import 'conversation_list_item.dart';
import 'inbox_state.dart';
import 'room.dart';

/// Persistent sidebar at ≥800px widths (spec §6.1). 240px wide.
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.username});

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

    return Container(
      color: TwilightColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader('PARTNER', theme),
          ...couples.map(
            (r) => ConversationListItem(
              key: Key('room-${r.roomId}'),
              label: r.displayName(username),
              selected: inbox.selectedRoomId == r.roomId,
              onTap: () =>
                  ref.read(inboxStateProvider.notifier).select(r.roomId),
            ),
          ),
          const SizedBox(height: 16),
          _sectionHeader('FAMILIARS', theme),
          ...familiars.map(
            (r) => ConversationListItem(
              key: Key('room-${r.roomId}'),
              label: r.displayName(username),
              selected: inbox.selectedRoomId == r.roomId,
              onTap: () =>
                  ref.read(inboxStateProvider.notifier).select(r.roomId),
            ),
          ),
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
              icon: const Icon(
                Icons.settings,
                color: TwilightColors.textMuted,
              ),
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
