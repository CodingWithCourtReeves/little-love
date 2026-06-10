import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/pairing/bip39_invite.dart';
import 'package:littlelove/pairing/invite_consume.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/wire/frames.dart';

class _RecordingTransport implements PairingTransport {
  String? capturedCode;
  Uint8List? capturedSig;

  @override
  Future<InviteCreatedFrame> createInvite() => throw UnimplementedError();

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async {
    capturedCode = code;
    capturedSig = signature;
    return InviteConsumedFrame(const RoomFramePeer(
      roomId: '01J',
      peerUsername: 'court',
      peerEd25519PubBase64: 'AAAA',
      peerX25519PubBase64: 'BBBB',
    ));
  }
}

void main() {
  test('signs the §8.5.1 domain-separated invite-consume input', () async {
    final id = await derivedIdentityFromSigningSeedForTest(
      Uint8List(32)..fillRange(0, 32, 0x01),
    );
    final t = _RecordingTransport();
    const code = 'abandon-abandon-abandon-ability';
    final consumed = await consumeInvite(
      transport: t,
      identity: id,
      code: code,
    );
    expect(t.capturedCode, code);
    expect(t.capturedSig, isNotNull);
    expect(t.capturedSig!.length, 64, reason: 'Ed25519 signature is 64 bytes');

    final canonical = decodeInviteCode(code);
    final signingInput = <int>[
      ...utf8.encode('littlelove.v0.2.invite-consume'),
      0x00,
      ...canonical,
    ];
    expect(signingInput.length, 63);
    final ok = await id.verify(signingInput, t.capturedSig!);
    expect(ok, isTrue);

    expect(consumed.roomId, '01J');
  });

  test('rejects malformed codes before touching the transport', () async {
    final id = await derivedIdentityFromSigningSeedForTest(
      Uint8List(32)..fillRange(0, 32, 0x01),
    );
    final t = _RecordingTransport();
    expect(
      () => consumeInvite(
        transport: t,
        identity: id,
        code: 'this-is-not-real',
      ),
      throwsA(isA<InviteCodeException>()),
    );
    expect(
      t.capturedCode,
      isNull,
      reason: 'must not send a frame for a malformed code',
    );
  });
}
