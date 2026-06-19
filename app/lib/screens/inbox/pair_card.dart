import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/account_local.dart';
import '../../theme/twilight.dart';
import '../create_chat/create_chat_pick_screen.dart';
import '../pair/enter_code.dart';
import '../pair/show_invite.dart';

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
            detail: 'Pick your partner, then send the invite.',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CreateChatPickScreen(selfUsername: account.username),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openEnterCode(BuildContext context, WidgetRef ref) =>
      openEnterCodeScreen(context, ref, account.username);
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
                border: Border.all(color: TwilightColors.accentSage),
                borderRadius: BorderRadius.circular(2),
              ),
              alignment: Alignment.center,
              child: Text(
                glyph,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: TwilightColors.accentSage,
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
