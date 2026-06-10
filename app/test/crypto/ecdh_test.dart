import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/crypto/ecdh.dart';
import 'package:littlelove/identity/keypair.dart';

void main() {
  group('ECDH room-key derivation (spec §5.1)', () {
    test('X25519 commutativity: A_priv·B_pub == B_priv·A_pub', () async {
      final a = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x11),
      );
      final b = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x22),
      );

      final keyA = await deriveRoomKey(
        me: a,
        peerX25519Pub: b.x25519PublicKey,
        roomId: '01J2QXKABCDEFGH',
      );
      final keyB = await deriveRoomKey(
        me: b,
        peerX25519Pub: a.x25519PublicKey,
        roomId: '01J2QXKABCDEFGH',
      );
      expect(keyA, keyB, reason: 'both sides must derive the same room key');
      expect(keyA.length, 32);
    });

    test(
      'room_id is mixed into HKDF info — different rooms → different keys',
      () async {
        final a = await derivedIdentityFromSigningSeedForTest(
          Uint8List(32)..fillRange(0, 32, 0x11),
        );
        final b = await derivedIdentityFromSigningSeedForTest(
          Uint8List(32)..fillRange(0, 32, 0x22),
        );
        final keyRoom1 = await deriveRoomKey(
          me: a,
          peerX25519Pub: b.x25519PublicKey,
          roomId: 'room-1',
        );
        final keyRoom2 = await deriveRoomKey(
          me: a,
          peerX25519Pub: b.x25519PublicKey,
          roomId: 'room-2',
        );
        expect(keyRoom1, isNot(equals(keyRoom2)));
      },
    );

    test(
      'HKDF salt matches spec §5.1 — value is "littlelove.v0.2.room"',
      () async {
        final a = await derivedIdentityFromSigningSeedForTest(
          Uint8List(32)..fillRange(0, 32, 0x11),
        );
        final b = await derivedIdentityFromSigningSeedForTest(
          Uint8List(32)..fillRange(0, 32, 0x22),
        );
        final key = await deriveRoomKey(
          me: a,
          peerX25519Pub: b.x25519PublicKey,
          roomId: '01J2QXKABCDEFGH',
        );
        final shared = await X25519().sharedSecretKey(
          keyPair: a.encryptionKeyPair,
          remotePublicKey: SimplePublicKey(
            b.x25519PublicKey,
            type: KeyPairType.x25519,
          ),
        );
        final sharedBytes = await shared.extractBytes();
        final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
          secretKey: SecretKey(sharedBytes),
          nonce: const [
            // "littlelove.v0.2.room" as UTF-8 bytes
            0x6c, 0x69, 0x74, 0x74, 0x6c, 0x65, 0x6c, 0x6f, 0x76, 0x65,
            0x2e, 0x76, 0x30, 0x2e, 0x32, 0x2e, 0x72, 0x6f, 0x6f, 0x6d,
          ],
          info: const [
            // "01J2QXKABCDEFGH" as UTF-8 bytes
            0x30, 0x31, 0x4a, 0x32, 0x51, 0x58, 0x4b, 0x41, 0x42, 0x43,
            0x44, 0x45, 0x46, 0x47, 0x48,
          ],
        );
        final expected = Uint8List.fromList(await out.extractBytes());
        expect(key, expected);
      },
    );
  });
}
