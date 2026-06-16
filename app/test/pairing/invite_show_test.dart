import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/pairing/qr.dart';
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
  Future<InviteCreatedFrame> createFamiliarInvite() =>
      throw UnimplementedError();

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => throw UnimplementedError();
}

class _FailingTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() async =>
      throw StateError('server down');

  @override
  Future<InviteCreatedFrame> createFamiliarInvite() =>
      throw UnimplementedError();

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => throw UnimplementedError();
}

void main() {
  testWidgets(
    'ShowInviteScreen displays the code and QR after createInvite resolves',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pairingTransportProvider.overrideWithValue(_StubTransport()),
          ],
          child: const MaterialApp(home: ShowInviteScreen()),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle();

      expect(find.text('amber-fern-locket-tide'), findsOneWidget);
      expect(find.byType(InviteQr), findsOneWidget);
    },
  );

  testWidgets('ShowInviteScreen surfaces transport errors', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pairingTransportProvider.overrideWithValue(_FailingTransport()),
        ],
        child: const MaterialApp(home: ShowInviteScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not create invite'), findsOneWidget);
  });
}
