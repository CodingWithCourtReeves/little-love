import 'package:flutter/material.dart';

import '../../identity/account_local.dart';
import '../../theme/app_palette.dart';
import 'inbox_shell.dart' show PairCard;

/// Dedicated screen hosting the three pair / new-chat CTAs. Pushed from the
/// sidebar's "+" button on wide layouts and the drawer's "New chat" entry on
/// mobile, so tapping always lands somewhere visible — even when the user
/// already has a room selected and the "empty-state" PairCard would otherwise
/// be hidden behind the conversation.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key, required this.account});

  final LocalAccount account;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        title: const Text('New chat'),
      ),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: PairCard(account: account),
            ),
          ),
        ),
      ),
    );
  }
}
