import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../conversation/conversation_page.dart';
import '../../conversation/message_store.dart';
import '../../conversation/room_key_cache.dart';
import '../../conversation/room_message_router.dart';
import '../../conversation/send_fanout.dart';
import '../../wire/message.dart';
import '../../identity/account_local.dart';
import '../../identity/current_identity.dart';
import '../../identity/keypair.dart';
import '../../inbox/drawer.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/layout_scaffold.dart';
import '../../inbox/navigation_rail.dart';
import '../../inbox/pending_invites_provider.dart';
import '../../inbox/read_state_provider.dart';
import '../../inbox/room.dart';
import '../../inbox/sidebar.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';
import '../create_chat/create_channel_sheet.dart';
import '../create_chat/create_chat_invite_screen.dart';
import '../create_chat/create_chat_pick_screen.dart';
import '../pair/bring_familiar.dart';
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
                    const Text(
                      'STEP 4 OF 4 · PAIR',
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
                      'Invite your partner',
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
                    PairCard(account: account),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (selectedId == null) {
      final home = defaultHomeRoomId(rooms, account.username);
      if (home != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(inboxStateProvider.notifier).select(home);
          ref.read(readStateProvider.notifier).markRead(home);
        });
        // One frame of empty canvas before selection lands.
        return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
      }
      // No rooms case is handled above; this is a defensive fallback.
      return const Scaffold(backgroundColor: TwilightColors.bgCanvas);
    }
    final room = rooms.firstWhere((r) => r.roomId == selectedId);
    // A "solo" room is one where Court is the only member AND a pending invite
    // exists for it — the user got here by tapping "Invite them with a code",
    // creating the room, then leaving the show-invite screen. Route them back
    // to the invite code instead of an empty conversation.
    final pending = ref.watch(pendingInvitesProvider);
    final dismissed = ref.watch(dismissedInvitesProvider);
    final isSolo =
        room.members.length == 1 &&
        room.members.first.username == account.username;
    if (isSolo &&
        pending.containsKey(room.roomId) &&
        !dismissed.contains(room.roomId)) {
      return CreateChatInviteScreen(
        roomId: room.roomId,
        onDone: () =>
            ref.read(dismissedInvitesProvider.notifier).dismiss(room.roomId),
      );
    }
    // Viewing a room marks it read. Done post-frame to avoid mutating a
    // provider during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readStateProvider.notifier).markRead(room.roomId);
    });
    return ConversationPage(
      key: ValueKey(selectedId),
      room: room,
      selfUsername: account.username,
      onSend: (text) => _sendEncrypted(ref, room, text),
      onRename: (newName) {
        final conn = ref.read(liveConnectionProvider).asData?.value;
        conn?.send(
          RenameRoomFrame(roomId: room.roomId, name: newName).toJson(),
        );
      },
      onNewChannel: () => showCreateChannelSheet(context, ref),
    );
  }

  Future<void> _sendEncrypted(WidgetRef ref, Room room, String text) async {
    try {
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
      // v0.3 servers do NOT echo Send back to the sender (the only other
      // copies live on the recipients' clients). Render the bubble locally
      // so the user sees their own message immediately. Keyed by the
      // SendFrame's UUID, which is also what the server will use to dedupe
      // — so even if a future server emits a SendAck with the same id, the
      // MessageStore.add() idempotency check de-dupes it.
      ref
          .read(messageStoreProvider(room.roomId).notifier)
          .add(
            Msg(
              id: frame.clientMsgId,
              from: account.username,
              to: room.members
                  .firstWhere(
                    (m) => m.username != account.username,
                    orElse: () => room.members.first,
                  )
                  .username,
              body: text,
              ts: DateTime.now().toUtc(),
            ),
          );
    } catch (e, st) {
      // ignore: avoid_print
      print('send failed: $e\n$st');
    }
  }
}

class PairCard extends ConsumerWidget {
  const PairCard({super.key, required this.account});
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
          const Divider(
            height: 1,
            thickness: 1,
            color: TwilightColors.borderSoft,
            indent: 18,
            endIndent: 18,
          ),
          _PairOption(
            glyph: '✦',
            title: 'Create a chat',
            detail: 'Pick partner + familiars, then send the invite.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CreateChatPickScreen(selfUsername: account.username),
              ),
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
            glyph: '◆',
            title: 'Add a familiar',
            detail: 'Generate a code your familiar CLI enters to join you.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BringFamiliarScreen(),
              ),
            ),
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
        builder: (_) =>
            EnterCodeScreen(identity: identity, selfUsername: account.username),
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
