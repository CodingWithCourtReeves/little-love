import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inbox/inbox_state.dart';
import '../../inbox/pending_invites_provider.dart';
import '../../inbox/room.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../pair/enter_code.dart';

/// Step 2 of 2 — show the 4-word code + QR + roster after `CreateRoom`.
///
/// Per mocks/v0.3/create-chat-invite.html. The screen reads the latest
/// pending invite from `pendingInvitesProvider`; if none exists yet (no
/// `RoomCreated` round-trip), it shows a "waiting" placeholder.
class CreateChatInviteScreen extends ConsumerWidget {
  const CreateChatInviteScreen({
    super.key,
    this.roomId,
    this.selfUsername,
    this.onDone,
  });

  /// When null, picks the room with the most recent pending invite.
  final String? roomId;

  /// The signed-in user's username. When provided, the screen offers an
  /// "I have my partner's code instead" escape into the enter-code flow — the
  /// only way back to accepting an invite once this solo room exists.
  final String? selfUsername;

  /// Invoked when the user taps "Done". This screen is rendered inline as the
  /// inbox detail pane (not a pushed route), so it must NOT pop the navigator —
  /// the caller dismisses it by changing inbox routing instead.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final username = selfUsername;
    final pending = ref.watch(pendingInvitesProvider);
    final inbox = ref.watch(inboxStateProvider);

    final targetRoomId = roomId ?? _latestPendingRoomId(pending, inbox.rooms);
    final invite = targetRoomId == null ? null : pending[targetRoomId];
    final room = targetRoomId == null
        ? null
        : _findRoom(inbox.rooms, targetRoomId);

    if (invite == null || room == null) {
      return Scaffold(
        backgroundColor: TwilightColors.bgCanvas,
        appBar: AppBar(
          backgroundColor: TwilightColors.bgSurface,
          title: const Text('Send invite code'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Waiting for the server to confirm the new chat…',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: TwilightColors.textMuted,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('Send invite code'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Send this code to your partner.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 22,
                color: TwilightColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your partner becomes a member the moment they enter this code.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: TwilightColors.textMuted,
              ),
            ),
            const SizedBox(height: 24),
            _CodeCard(invite: invite),
            const SizedBox(height: 16),
            _QrCard(invite: invite),
            const SizedBox(height: 24),
            _RosterList(room: room),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('copy-code-button'),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: invite.code)),
              child: const Text('Copy code'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('done-button'),
              onPressed: onDone,
              child: const Text('Done'),
            ),
            if (username != null)
              TextButton(
                key: const Key('have-partner-code-button'),
                onPressed: () => openEnterCodeScreen(context, ref, username),
                child: const Text("I have my partner's code instead"),
              ),
          ],
        ),
      ),
    );
  }

  String? _latestPendingRoomId(
    Map<String, PendingInvite> pending,
    List<Room> rooms,
  ) {
    if (pending.isEmpty) return null;
    final byCreated = [...rooms]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final r in byCreated) {
      if (pending.containsKey(r.roomId)) return r.roomId;
    }
    return pending.keys.first;
  }

  Room? _findRoom(List<Room> rooms, String id) {
    for (final r in rooms) {
      if (r.roomId == id) return r;
    }
    return null;
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.invite});
  final PendingInvite invite;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAFB),
        border: Border.all(color: TwilightColors.borderSoft),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '4-WORD INVITE',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 2.0,
              color: TwilightColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            invite.code,
            key: const Key('invite-code-words'),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 22,
              fontWeight: FontWeight.w500,
              color: TwilightColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({required this.invite});
  final PendingInvite invite;

  @override
  Widget build(BuildContext context) {
    final hasQr = invite.qrPngBase64.isNotEmpty;
    Uint8List? bytes;
    if (hasQr) {
      try {
        bytes = base64.decode(invite.qrPngBase64);
      } catch (_) {
        bytes = null;
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAFB),
        border: Border.all(color: TwilightColors.borderSoft),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SAME CODE · QR',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 2.0,
              color: TwilightColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: bytes != null
                ? Image.memory(
                    bytes,
                    key: const Key('invite-qr-image'),
                    width: 180,
                    height: 180,
                    fit: BoxFit.contain,
                  )
                : Container(
                    key: const Key('invite-qr-placeholder'),
                    width: 180,
                    height: 180,
                    color: TwilightColors.bgSurface,
                  ),
          ),
        ],
      ),
    );
  }
}

class _RosterList extends StatelessWidget {
  const _RosterList({required this.room});
  final Room room;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAFB),
        border: Border.all(color: TwilightColors.borderSoft),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ROOM ROSTER',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              letterSpacing: 2.0,
              color: TwilightColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          for (final m in room.members) ...[
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: TwilightColors.accentUser,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    m.username.isEmpty ? '?' : m.username[0].toUpperCase(),
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      color: Color(0xFFFFFAFB),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    m.username,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                ),
                const Text(
                  'IN',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: TwilightColors.accentSage,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: Border.all(color: TwilightColors.accentPartner),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Text(
                  '?',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                    color: TwilightColors.accentPartner,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Partner',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: TwilightColors.textPrimary,
                  ),
                ),
              ),
              const Text(
                'PENDING',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  color: TwilightColors.accentUser,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
