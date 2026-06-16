import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/pairing/qr.dart';
import 'package:littlelove/screens/pair/bring_familiar.dart';
import 'package:littlelove/wire/frames.dart';

class _StubTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() => throw UnimplementedError();

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

class _FailingTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() => throw UnimplementedError();

  @override
  Future<InviteCreatedFrame> createFamiliarInvite() async =>
      throw StateError('server down');

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets('BringFamiliarScreen shows the code and QR after resolve', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingTransportProvider.overrideWithValue(_StubTransport()),
        ],
        child: const MaterialApp(home: BringFamiliarScreen()),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('cedar-otter-prism-vault'), findsOneWidget);
    expect(find.byType(InviteQr), findsOneWidget);
  });

  testWidgets('BringFamiliarScreen surfaces transport errors', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingTransportProvider.overrideWithValue(_FailingTransport()),
        ],
        child: const MaterialApp(home: BringFamiliarScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not create invite'), findsOneWidget);
  });
}
