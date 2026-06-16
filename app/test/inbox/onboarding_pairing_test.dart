import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/screens/inbox/inbox_shell.dart';

void main() {
  testWidgets('unpaired user sees the pairing onboarding step', (t) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'x',
      x25519PubBase64: 'y',
      createdAt: DateTime.utc(2026, 6, 14),
    );
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: InboxShell(account: acc)),
      ),
    );
    await t.pump();
    expect(find.text('Invite your partner'), findsOneWidget);
  });
}
