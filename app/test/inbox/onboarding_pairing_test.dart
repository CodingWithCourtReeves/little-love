import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/inbox/home_screen.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

/// A pairing transport whose calls never resolve — lets PairingScreen mount
/// and show its spinner without a real socket.
class _PendingTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() =>
      Completer<InviteCreatedFrame>().future;
  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => Completer<InviteConsumedFrame>().future;
}

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
        overrides: [
          inboxSyncedProvider.overrideWith((ref) => true),
          liveConnectionProvider.overrideWith(
            (_) => Completer<LiveConnection>().future,
          ),
          pairingTransportProvider.overrideWithValue(_PendingTransport()),
        ],
        child: MaterialApp(home: HomeScreen(account: acc)),
      ),
    );
    await t.pump();
    expect(find.text('PAIR WITH YOUR PARTNER'), findsOneWidget);
  });
}
