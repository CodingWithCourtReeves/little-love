import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../conversation/conversation_page.dart';
import '../../conversation/message_store.dart';
import '../../identity/account_local.dart';
import '../../inbox/drawer.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/layout_scaffold.dart';
import '../../inbox/navigation_rail.dart';
import '../../inbox/room.dart';
import '../../inbox/sidebar.dart';
import '../../theme/twilight.dart';
import '../../wire/message.dart';

/// Top-level inbox screen for a signed-in user. Wraps `LayoutScaffold` and
/// supplies sidebar / rail / drawer chrome around a `ConversationPage` keyed
/// by the currently selected `roomId`.
class InboxShell extends ConsumerWidget {
  const InboxShell({super.key, required this.account});

  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    final detail = _detail(context, ref, inbox.selectedRoomId, inbox.rooms);

    return LayoutScaffold(
      sidebar: Sidebar(username: account.username),
      rail: const NavigationRailChrome(),
      drawer: DrawerContent(username: account.username),
      detail: detail,
    );
  }

  Widget _detail(
    BuildContext context,
    WidgetRef ref,
    String? selectedId,
    List<Room> rooms,
  ) {
    if (rooms.isEmpty) {
      return Scaffold(
        backgroundColor: TwilightColors.bgCanvas,
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No conversations yet.\nPair with your partner to start a chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: TwilightColors.textMuted),
            ),
          ),
        ),
      );
    }
    if (selectedId == null) {
      return Scaffold(
        backgroundColor: TwilightColors.bgCanvas,
        body: const Center(
          child: Text(
            'Select a conversation',
            style: TextStyle(color: TwilightColors.textMuted),
          ),
        ),
      );
    }
    final room = rooms.firstWhere((r) => r.roomId == selectedId);
    return ConversationPage(
      key: ValueKey(selectedId),
      roomId: selectedId,
      contactDisplayName: room.peerUsername,
      onSend: (text) => _localSend(ref, selectedId, text),
    );
  }

  /// v0.2 placeholder: append a local Msg with `from = account.username` so
  /// the demo round-trips locally. The integration session replaces this
  /// with the real WSS `Send` frame path.
  void _localSend(WidgetRef ref, String roomId, String text) {
    final msg = Msg(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      from: account.username,
      to: roomId,
      body: text,
      ts: DateTime.now().toUtc(),
    );
    ref.read(messageStoreProvider(roomId).notifier).add(msg);
  }
}
