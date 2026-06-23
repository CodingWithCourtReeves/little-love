import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_signaling.dart';
import 'package:littlelove/pairing/encryption.dart';
import 'package:littlelove/wire/frames.dart';

Uint8List _roomKey(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i + seed) & 0xff));

void main() {
  test(
    'deriveSigKey is deterministic for the same room key + call id',
    () async {
      final k = _roomKey(1);
      final a = await deriveSigKey(k, 'call-1');
      final b = await deriveSigKey(k, 'call-1');
      expect(a, equals(b));
      expect(a.length, 32);
    },
  );

  test('deriveSigKey differs per call id and per room key', () async {
    final k = _roomKey(1);
    final c1 = await deriveSigKey(k, 'call-1');
    final c2 = await deriveSigKey(k, 'call-2');
    final other = await deriveSigKey(_roomKey(2), 'call-1');
    expect(c1, isNot(equals(c2)));
    expect(c1, isNot(equals(other)));
  });

  test('encrypt/decrypt round-trips an SDP under the sig key', () async {
    final key = await deriveSigKey(_roomKey(7), 'call-x');
    const sdp = 'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n...';
    final wire = await encryptSignal(key, sdp);
    expect(wire, isNot(contains('v=0')), reason: 'ciphertext, not plaintext');
    expect(await decryptSignal(key, wire), sdp);
  });

  test('a frame for the wrong call does not decrypt', () async {
    final right = await deriveSigKey(_roomKey(7), 'call-x');
    final wrong = await deriveSigKey(_roomKey(7), 'call-y');
    final wire = await encryptSignal(right, 'candidate:1 1 udp ...');
    expect(await decryptSignal(wrong, wire), cannotDecryptSentinel);
  });

  test('inbound CallInvite frame parses with from + offer', () {
    final f = RoomServerFrame.fromJson(<String, Object?>{
      'kind': 'CallInvite',
      'room_id': 'r1',
      'call_id': 'c1',
      'from': 'court',
      'offer': 'ENCSDP',
    });
    expect(f, isA<CallInviteFrame>());
    final inv = f as CallInviteFrame;
    expect(inv.from, 'court');
    expect(inv.offer, 'ENCSDP');
  });

  test('outbound call frames carry the right kind + fields', () {
    expect(
      const CallInviteClientFrame(
        roomId: 'r1',
        callId: 'c1',
        offer: 'O',
      ).toJson(),
      <String, Object?>{
        'kind': 'CallInvite',
        'room_id': 'r1',
        'call_id': 'c1',
        'offer': 'O',
      },
    );
    expect(
      const CallHangupClientFrame(
        roomId: 'r1',
        callId: 'c1',
        reason: 'decline',
      ).toJson()['reason'],
      'decline',
    );
  });
}
