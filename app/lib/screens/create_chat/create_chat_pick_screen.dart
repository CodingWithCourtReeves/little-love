import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inbox/inbox_state.dart';
import '../../inbox/owned_bots_provider.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';
import 'create_chat_invite_screen.dart';

/// Step 1 of 2 — pick partner + familiars, then issue `CreateRoom`.
///
/// Per mocks/v0.3/create-chat-pick.html. `botAccountIds` is left empty for now:
/// the wire `Member` shape (spec §7.1) does not carry account_id, so the
/// client cannot send familiar IDs without a separate amendment. The picker
/// still renders owned bots so the UI is functional once the amendment lands.
class CreateChatPickScreen extends ConsumerStatefulWidget {
  const CreateChatPickScreen({super.key, required this.selfUsername});

  final String selfUsername;

  @override
  ConsumerState<CreateChatPickScreen> createState() =>
      _CreateChatPickScreenState();
}

class _CreateChatPickScreenState extends ConsumerState<CreateChatPickScreen> {
  bool _includePartner = false;
  final _selectedBotUsernames = <String>{};

  String? _knownPartnerUsername() {
    final rooms = ref.read(inboxStateProvider).rooms;
    for (final r in rooms) {
      for (final m in r.members) {
        if (!m.isBot && m.username != widget.selfUsername) return m.username;
      }
    }
    return null;
  }

  void _toggleBot(String username) {
    setState(() {
      if (_selectedBotUsernames.contains(username)) {
        _selectedBotUsernames.remove(username);
      } else {
        _selectedBotUsernames.add(username);
      }
    });
  }

  Future<void> _create() async {
    final connAsync = ref.read(liveConnectionProvider);
    final conn = connAsync.asData?.value;
    if (conn == null) return;
    conn.send(
      CreateRoomFrame(
        botAccountIds: const [],
        inviteHumanPartner: _includePartner,
      ).toJson(),
    );
    if (_includePartner) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const CreateChatInviteScreen()),
      );
    } else {
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(ownedBotsProvider);
    final partnerUsername = _knownPartnerUsername();

    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('New chat'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Who's in this chat?",
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w500,
                fontSize: 26,
                color: TwilightColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "You'll always be in it. Pick your partner if they should be, "
              "and any familiars you want listening. Membership is fixed "
              "once the chat is created.",
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                color: TwilightColors.textMuted,
              ),
            ),
            const SizedBox(height: 24),
            const _GroupHeader(label: '01 · PARTNER'),
            const SizedBox(height: 8),
            _PartnerRow(
              partnerUsername: partnerUsername,
              checked: _includePartner,
              onTap: () => setState(() => _includePartner = !_includePartner),
            ),
            const SizedBox(height: 24),
            const _GroupHeader(label: '02 · FAMILIARS'),
            const SizedBox(height: 8),
            if (bots.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No familiars yet. Bots you own will appear here.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    color: TwilightColors.textMuted,
                  ),
                ),
              ),
            for (final b in bots)
              _FamiliarRow(
                bot: b,
                checked: _selectedBotUsernames.contains(b.username),
                onTap: () => _toggleBot(b.username),
              ),
            const SizedBox(height: 32),
            FilledButton(
              key: const Key('create-chat-button'),
              onPressed: _create,
              child: const Text('Create chat'),
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
      style: const TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 10,
        letterSpacing: 2.0,
        color: TwilightColors.textMuted,
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No partner paired yet — use "Invite them with a code" first.',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            color: TwilightColors.textMuted,
          ),
        ),
      );
    }
    return _PickRow(
      key: const Key('partner-row'),
      avBg: TwilightColors.accentPartner,
      initial: username[0].toUpperCase(),
      title: username,
      subtitle: 'PARTNER',
      checked: checked,
      onTap: onTap,
    );
  }
}

class _FamiliarRow extends StatelessWidget {
  const _FamiliarRow({
    required this.bot,
    required this.checked,
    required this.onTap,
  });

  final Member bot;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final owner = bot.ownerUsername;
    return _PickRow(
      key: Key('familiar-row-${bot.username}'),
      avBg: TwilightColors.accentFamiliar,
      initial: bot.username.isEmpty ? '?' : bot.username[0].toUpperCase(),
      title: bot.username,
      subtitle: owner == null
          ? 'FAMILIAR'
          : "FAMILIAR · ${owner.toUpperCase()}",
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
          color: checked ? TwilightColors.bgSurface : Colors.transparent,
          border: Border.all(color: TwilightColors.borderSoft),
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
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 10,
                      letterSpacing: 1.2,
                      color: TwilightColors.textMuted,
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
        color: checked ? TwilightColors.accentUser : Colors.transparent,
        border: Border.all(
          color: checked ? TwilightColors.accentUser : TwilightColors.textMuted,
        ),
      ),
      alignment: Alignment.center,
      child: checked
          ? const Icon(Icons.check, size: 14, color: Color(0xFFFFFAFB))
          : null,
    );
  }
}
