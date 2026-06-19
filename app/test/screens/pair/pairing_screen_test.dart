import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/pair/pairing_screen.dart';
import 'package:littlelove/wire/frames.dart';

class _FakeTransport implements PairingTransport {
  String? consumedCode;
  @override
  Future<InviteCreatedFrame> createInvite() async => InviteCreatedFrame(
    code: 'abandon-pilot-react-zoo',
    qrPngBase64: '',
    expiresAt: DateTime.utc(2026, 6, 20),
  );
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async {
    consumedCode = code;
    return const InviteConsumedFrame(roomId: 'r1', name: '', members: []);
  }
}

Widget _app(_FakeTransport t) => ProviderScope(
  overrides: [
    pairingTransportProvider.overrideWithValue(t),
    // A throwaway identity so consume can sign without a keystore.
    currentIdentityProvider.overrideWith(
      (_) =>
          deriveIdentity(Uint8List.fromList(List<int>.generate(16, (i) => i))),
    ),
  ],
  child: const MaterialApp(
    // PairingScreen is a Scaffold body in production (Material comes from
    // HomeScreen's Scaffold); mirror that here so its TextField has an
    // ancestor Material.
    home: Scaffold(body: PairingScreen(selfUsername: 'court')),
  ),
);

void main() {
  testWidgets('shows your code, the link, and the QR', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_app(t));
    await tester.pumpAndSettle();
    expect(find.text('abandon-pilot-react-zoo'), findsOneWidget);
    expect(
      find.text('https://littlelove.dev/pair/abandon-pilot-react-zoo'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pairing-enter-field')), findsOneWidget);
  });

  testWidgets('entering a code drives consume', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_app(t));
    await tester.pumpAndSettle();
    // A real, decodable BIP39 code (the screen validates before consuming).
    await tester.enterText(
      find.byKey(const Key('pairing-enter-field')),
      'gather-pilot-rocket-zoo',
    );
    final joinButton = find.byKey(const Key('pairing-join-button'));
    await tester.ensureVisible(joinButton);
    await tester.tap(joinButton);
    await tester.pumpAndSettle();
    expect(t.consumedCode, 'gather-pilot-rocket-zoo');
  });
}
