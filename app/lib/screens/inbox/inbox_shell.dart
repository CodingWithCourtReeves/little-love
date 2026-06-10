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
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: const Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 'No conversations yet' kept verbatim for widget tests.
                    Text(
                      'No conversations yet',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.accentFamiliar,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      'Pair with your partner to begin.',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 28,
                        fontWeight: FontWeight.w500,
                        height: 1.14,
                        letterSpacing: -0.6,
                        color: TwilightColors.textPrimary,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'A pairing handshake exchanges public keys directly '
                      'between your two devices. Until that happens, there is '
                      'nothing for the server to deliver.',
                      style: TwilightType.lede,
                    ),
                    SizedBox(height: 28),
                    _PairCard(),
                  ],
                ),
              ),
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

class _PairCard extends StatelessWidget {
  const _PairCard();
  @override
  Widget build(BuildContext context) {
    return Material(
      color: TwilightColors.bubblePartnerBg,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: TwilightColors.borderSoft),
        borderRadius: BorderRadius.all(Radius.circular(2)),
      ),
      elevation: 0,
      child: Column(
        children: [
          _PairOption(
            glyph: '+',
            title: 'Invite them with a code',
            detail: 'Generates a one-time code they enter on their device.',
            onTap: () {}, // pairing-WT wires this.
          ),
          const Divider(
            height: 1,
            thickness: 1,
            color: TwilightColors.borderSoft,
            indent: 18,
            endIndent: 18,
          ),
          _PairOption(
            glyph: '⌗',
            title: 'I have an invite code',
            detail: 'Enter a code your partner sent you.',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _PairOption extends StatelessWidget {
  const _PairOption({
    required this.glyph,
    required this.title,
    required this.detail,
    required this.onTap,
  });
  final String glyph;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                border: Border.all(color: TwilightColors.accentFamiliar),
                borderRadius: BorderRadius.circular(2),
              ),
              alignment: Alignment.center,
              child: Text(
                glyph,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: TwilightColors.accentFamiliar,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(detail, style: TwilightType.lede),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              '→',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                color: TwilightColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
