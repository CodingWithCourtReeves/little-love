import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../conversation/conversation_page.dart';
import '../../conversation/room_key_cache.dart';
import '../../conversation/room_message_router.dart';
import '../../conversation/send_fanout.dart';
import '../../identity/account_local.dart';
import '../../identity/current_identity.dart';
import '../../identity/keypair.dart';
import '../../inbox/drawer.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/layout_scaffold.dart';
import '../../inbox/navigation_rail.dart';
import '../../inbox/room.dart';
import '../../inbox/sidebar.dart';
import '../../theme/twilight.dart';
import '../../wire/live_connection.dart';
import '../pair/enter_code.dart';
import '../pair/show_invite.dart';

/// Top-level inbox screen for a signed-in user. Wraps `LayoutScaffold` and
/// supplies sidebar / rail / drawer chrome around a `ConversationPage` keyed
/// by the currently selected `roomId`.
class InboxShell extends ConsumerWidget {
  const InboxShell({super.key, required this.account});

  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Activate the router for this signed-in session. Reading the provider
    // is enough — it stays alive while InboxShell is mounted.
    ref
        .watch(liveConnectionProvider)
        .whenData((_) => ref.watch(roomMessageRouterProvider));

    final inbox = ref.watch(inboxStateProvider);
    final detail = _detail(context, ref, inbox.selectedRoomId, inbox.rooms);

    return LayoutScaffold(
      sidebar: Sidebar(username: account.username),
      rail: NavigationRailChrome(username: account.username),
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
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 'No conversations yet' kept verbatim for widget tests.
                    const Text(
                      'No conversations yet',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 11,
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.accentFamiliar,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
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
                    const SizedBox(height: 12),
                    const Text(
                      'A pairing handshake exchanges public keys directly '
                      'between your two devices. Until that happens, there is '
                      'nothing for the server to deliver.',
                      style: TwilightType.lede,
                    ),
                    const SizedBox(height: 28),
                    _PairCard(account: account),
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
      contactDisplayName: room.displayName(account.username),
      onSend: (text) => _sendEncrypted(ref, room, text),
    );
  }

  Future<void> _sendEncrypted(WidgetRef ref, Room room, String text) async {
    final me = await ref.read(currentIdentityProvider.future);
    final cache = ref.read(roomKeyCacheProvider);
    final frame = await buildSendFrame(
      room: room,
      me: me,
      selfUsername: account.username,
      plaintext: text,
      cache: cache,
    );
    final conn = ref.read(liveConnectionProvider).requireValue;
    conn.send(frame.toJson());
  }
}

class _PairCard extends ConsumerWidget {
  const _PairCard({required this.account});
  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ShowInviteScreen()),
            ),
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
            onTap: () => _openEnterCode(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _openEnterCode(BuildContext context, WidgetRef ref) async {
    final DerivedIdentity identity;
    try {
      identity = await ref.read(currentIdentityProvider.future);
    } on StateError {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unlock identity — please sign in again.'),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EnterCodeScreen(identity: identity),
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
