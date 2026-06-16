import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/wire/frames.dart';

class _FakeTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() async => InviteCreatedFrame(
    code: 'a-b-c-d',
    qrPngBase64: 'AAAA',
    expiresAt: DateTime.utc(2026, 6, 9, 18),
  );

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async => const InviteConsumedFrame(
    roomId: '01J',
    name: '',
    members: [
      Member(
        username: 'court',
        ed25519PubBase64: 'AAAA',
        x25519PubBase64: 'BBBB',
      ),
    ],
  );
}

void main() {
  test('fake transport satisfies the interface', () async {
    final t = _FakeTransport();
    final created = await t.createInvite();
    expect(created.code, 'a-b-c-d');
    final consumed = await t.consumeInvite(
      code: 'a-b-c-d',
      signature: Uint8List(64),
    );
    expect(consumed.roomId, '01J');
  });

  test('default provider requires liveConnectionProvider to be ready', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      () => container.read(pairingTransportProvider),
      throwsA(anything),
      reason:
          'reading the transport without a ready liveConnectionProvider must '
          'fail loudly rather than silently constructing a no-op',
    );
  });
}
