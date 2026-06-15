import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/invite_create.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/wire/frames.dart';

class _StubTransport implements PairingTransport {
  bool called = false;
  @override
  Future<InviteCreatedFrame> createInvite() async {
    called = true;
    return InviteCreatedFrame(
      code: 'aim-primary-fetch-primary',
      qrPngBase64: 'AAAA',
      expiresAt: DateTime.utc(2026, 6, 9, 18),
    );
  }

  @override
  Future<InviteCreatedFrame> createFamiliarInvite() => throw UnimplementedError();

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) => throw UnimplementedError();
}

void main() {
  test('createInvite returns the InviteCreated payload', () async {
    final t = _StubTransport();
    final out = await createInvite(t);
    expect(t.called, isTrue);
    expect(out.code, 'aim-primary-fetch-primary');
    expect(out.qrPngBase64, 'AAAA');
  });
}
