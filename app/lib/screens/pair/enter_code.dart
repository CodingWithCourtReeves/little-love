import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/keypair.dart';
import '../../identity/providers.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/room.dart';
import '../../pairing/bip39_invite.dart';
import '../../pairing/invite_consume.dart';
import '../../pairing/pairing_transport.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/rest_client.dart';

/// Receiver-side pairing screen: code → preview (full v0.3 roster) → confirm
/// → consume → add Room.
///
/// The roster card mirrors the v0.3 invite-preview-multi mock.
class EnterCodeScreen extends ConsumerStatefulWidget {
  const EnterCodeScreen({
    super.key,
    required this.identity,
    required this.selfUsername,
  });

  /// The signed-in user's derived identity (used to sign the §8.5.1 input).
  final DerivedIdentity identity;

  /// The signed-in user's username — used to render the `You · …` row.
  final String selfUsername;

  @override
  ConsumerState<EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends ConsumerState<EnterCodeScreen> {
  final _controller = TextEditingController();
  String? _error;
  InvitePreviewResponse? _preview;
  String? _pendingCode;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doPreview() async {
    final code = _controller.text.trim();
    setState(() {
      _error = null;
      _preview = null;
      _busy = true;
    });
    try {
      decodeInviteCode(code);
    } on InviteCodeException {
      setState(() {
        _error = 'Invalid invite code';
        _busy = false;
      });
      return;
    }
    try {
      final rest = ref.read(restClientProvider);
      final preview = await rest.previewInvite(code);
      setState(() {
        _preview = preview;
        _pendingCode = code;
        _busy = false;
      });
    } on InviteNotFoundException {
      setState(() {
        _error = 'No such invite — double-check the code.';
        _busy = false;
      });
    } on InviteGoneException {
      setState(() {
        _error = 'That invite has expired or already been used.';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not check that code: $e';
        _busy = false;
      });
    }
  }

  Future<void> _doConfirm() async {
    final preview = _preview;
    final code = _pendingCode;
    if (preview == null || code == null) return;
    setState(() => _busy = true);
    try {
      final transport = ref.read(pairingTransportProvider);
      final consumed = await consumeInvite(
        transport: transport,
        identity: widget.identity,
        code: code,
      );
      final room = Room(
        roomId: consumed.roomId,
        name: consumed.name,
        members: consumed.members,
        createdAt: DateTime.now().toUtc(),
      );
      ref.read(inboxStateProvider.notifier).setRooms([room]);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = 'Could not pair: $e';
        _busy = false;
      });
    }
  }

  String? _inviterUsername(InvitePreviewResponse preview) {
    for (final m in preview.members) {
      if (m.username != widget.selfUsername) return m.username;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('Enter invite code'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('enter-code-field'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'four words separated by dashes',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy && preview == null,
            ),
            const SizedBox(height: 16),
            if (preview == null)
              FilledButton(
                key: const Key('preview-button'),
                onPressed: _busy ? null : _doPreview,
                child: const Text('Look up'),
              ),
            if (preview != null) ...[
              _PreviewHeader(inviterUsername: _inviterUsername(preview)),
              const SizedBox(height: 16),
              _RosterCard(
                members: preview.members,
                selfUsername: widget.selfUsername,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('confirm-pair-button'),
                onPressed: _busy ? null : _doConfirm,
                child: const Text('Join chat'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({required this.inviterUsername});
  final String? inviterUsername;

  @override
  Widget build(BuildContext context) {
    final inviter = inviterUsername;
    final text = inviter == null
        ? "You've been invited to a chat."
        : 'Pair with @$inviter?';
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: TwilightColors.textPrimary,
      ),
    );
  }
}

class _RosterCard extends StatelessWidget {
  const _RosterCard({required this.members, required this.selfUsername});

  final List<Member> members;
  final String selfUsername;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('preview-roster-card'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAFB),
        border: Border.all(color: const Color(0xFFD9C7CD)),
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
          const SizedBox(height: 14),
          for (final m in members) ...[
            _MemberRow(member: m, isSelf: m.username == selfUsername),
            const SizedBox(height: 12),
          ],
          if (!members.any((m) => m.username == selfUsername))
            _MemberRow(
              member: Member(
                username: selfUsername,
                ed25519PubBase64: '',
                x25519PubBase64: '',
              ),
              isSelf: true,
            ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.isSelf});

  final Member member;
  final bool isSelf;

  String _label() {
    if (isSelf) return 'You · ${member.username}';
    return member.username;
  }

  String _role() {
    if (isSelf) return 'JOINING';
    return 'HOST';
  }

  Color _avColor() {
    return TwilightColors.accentUser;
  }

  @override
  Widget build(BuildContext context) {
    final initial = member.username.isEmpty
        ? '?'
        : member.username[0].toUpperCase();
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isSelf ? Colors.transparent : _avColor(),
            shape: BoxShape.circle,
            border: isSelf ? Border.all(color: _avColor()) : null,
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 13,
              color: isSelf ? _avColor() : const Color(0xFFFFFAFB),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _label(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w500,
              fontSize: 15,
              color: TwilightColors.textPrimary,
            ),
          ),
        ),
        Text(
          _role(),
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10,
            letterSpacing: 1.2,
            color: TwilightColors.textMuted,
          ),
        ),
      ],
    );
  }
}
