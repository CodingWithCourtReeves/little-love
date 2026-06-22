import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inbox/inbox_state.dart';
import '../../theme/app_palette.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';

/// "New chat" — name the chat and optionally include your partner, then
/// issue `CreateRoom`.
class CreateChatPickScreen extends ConsumerStatefulWidget {
  const CreateChatPickScreen({super.key, required this.selfUsername});

  final String selfUsername;

  @override
  ConsumerState<CreateChatPickScreen> createState() =>
      _CreateChatPickScreenState();
}

class _CreateChatPickScreenState extends ConsumerState<CreateChatPickScreen> {
  bool _includePartner = false;
  bool _submitting = false;
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String? _knownPartnerUsername() {
    final rooms = ref.read(inboxStateProvider).rooms;
    for (final r in rooms) {
      for (final m in r.members) {
        if (m.username != widget.selfUsername) return m.username;
      }
    }
    return null;
  }

  Future<void> _create() async {
    if (_submitting) return;
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected — try again in a moment.')),
      );
      return;
    }
    setState(() => _submitting = true);
    final rawName = _nameController.text.trim();
    conn.send(
      CreateRoomFrame(
        name: rawName.isEmpty ? null : rawName,
        inviteHumanPartner: _includePartner,
      ).toJson(),
    );
    if (!mounted) return;
    // Pop back to the inbox root; the router selects the new room when the
    // RoomCreated frame lands, so the user arrives in the conversation.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final partnerUsername = _knownPartnerUsername();

    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        title: const Text('New chat'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Who's in this chat?",
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 26,
                color: context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "You'll always be in it. Pick your partner if they should be. "
              "Membership is fixed once the chat is created.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: context.palette.textMuted,
              ),
            ),
            const SizedBox(height: 24),
            const _GroupHeader(label: '00 · NAME (OPTIONAL)'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('chat-name-field'),
              controller: _nameController,
              decoration: const InputDecoration(
                hintText: 'e.g. travel planning, weekly check-in',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 64,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                color: context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            const _GroupHeader(label: '01 · PARTNER'),
            const SizedBox(height: 8),
            _PartnerRow(
              partnerUsername: partnerUsername,
              checked: _includePartner,
              onTap: () => setState(() => _includePartner = !_includePartner),
            ),
            if (_includePartner && partnerUsername != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  "@$partnerUsername joins the moment the chat is created — "
                  "no code, no waiting. You're already linked.",
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    color: context.palette.textMuted,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
            if (partnerUsername == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  "Nothing to put in a chat yet. Pair with your partner "
                  "first, then come back.",
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: context.palette.textMuted,
                  ),
                ),
              ),
            Builder(
              builder: (context) {
                final hasSelection = _includePartner && partnerUsername != null;
                return FilledButton(
                  key: const Key('create-chat-button'),
                  onPressed: (!hasSelection || _submitting) ? null : _create,
                  child: const Text('Create chat'),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        letterSpacing: 2.0,
        color: context.palette.textMuted,
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          color: context.palette.textMuted,
        ),
      ),
    );
  }
}

class _PartnerRow extends StatelessWidget {
  const _PartnerRow({
    required this.partnerUsername,
    required this.checked,
    required this.onTap,
  });

  final String? partnerUsername;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final username = partnerUsername;
    if (username == null) {
      return const _EmptyHint(
        key: Key('partner-empty-hint'),
        text: 'No partner yet. Send an invite first.',
      );
    }
    return _PickRow(
      key: const Key('partner-row'),
      avBg: context.palette.accentPartner,
      initial: username[0].toUpperCase(),
      title: username,
      subtitle: 'PARTNER',
      checked: checked,
      onTap: onTap,
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.avBg,
    required this.initial,
    required this.title,
    required this.subtitle,
    required this.checked,
    required this.onTap,
  });

  final Color avBg;
  final String initial;
  final String title;
  final String subtitle;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: checked ? context.palette.bgSurface : Colors.transparent,
          border: Border.all(color: context.palette.borderSoft),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: avBg, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                  color: Color(0xFFFFFAFB),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                      color: context.palette.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      letterSpacing: 1.2,
                      color: context.palette.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            _Checkbox(checked: checked),
          ],
        ),
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.checked});
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: checked ? context.palette.accentUser : Colors.transparent,
        border: Border.all(
          color: checked
              ? context.palette.accentUser
              : context.palette.textMuted,
        ),
      ),
      alignment: Alignment.center,
      child: checked
          ? const Icon(Icons.check, size: 14, color: Color(0xFFFFFAFB))
          : null,
    );
  }
}
