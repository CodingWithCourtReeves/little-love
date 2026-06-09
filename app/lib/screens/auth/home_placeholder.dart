import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/account_local.dart';

class HomePlaceholder extends ConsumerWidget {
  const HomePlaceholder({super.key, required this.account});
  final LocalAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('Signed in as @${account.username}')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Inbox coming soon.', textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
