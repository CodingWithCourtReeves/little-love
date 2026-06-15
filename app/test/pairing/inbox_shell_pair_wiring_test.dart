import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/inbox/inbox_shell.dart';
import 'package:littlelove/screens/pair/bring_familiar.dart';
import 'package:littlelove/screens/pair/show_invite.dart';
import 'package:littlelove/wire/frames.dart';

class _StubTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() async => InviteCreatedFrame(
    code: 'amber-fern-locket-tide',
    qrPngBase64: 'AAAA',
    expiresAt: DateTime.utc(2026, 6, 9, 18),
  );

  @override
  Future<InviteCreatedFrame> createFamiliarInvite() async => InviteCreatedFrame(
    code: 'cedar-otter-prism-vault',
    qrPngBase64: 'AAAA',
    expiresAt: DateTime.utc(2026, 6, 15, 18),
  );

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets('tapping "Invite them with a code" opens ShowInviteScreen', (
    tester,
  ) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingTransportProvider.overrideWithValue(_StubTransport()),
        ],
        child: MaterialApp(home: InboxShell(account: acc)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Invite them with a code'));
    await tester.pumpAndSettle();

    expect(find.byType(ShowInviteScreen), findsOneWidget);
  });

  testWidgets('tapping "Add a familiar" opens BringFamiliarScreen', (
    tester,
  ) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingTransportProvider.overrideWithValue(_StubTransport()),
        ],
        child: MaterialApp(home: InboxShell(account: acc)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a familiar'));
    await tester.pumpAndSettle();

    expect(find.byType(BringFamiliarScreen), findsOneWidget);
  });
}
