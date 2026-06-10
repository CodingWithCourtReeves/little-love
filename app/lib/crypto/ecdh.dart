import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/keypair.dart';

/// Spec §5.1 HKDF salt. Pinned — any change is a wire-incompat protocol bump.
const _roomKeyHkdfSalt = 'littlelove.v0.2.room';

/// Compute the 32-byte per-room AEAD key per spec §5.1:
///   shared = X25519(me_priv, peer_pub)
///   room_key = HKDF-SHA256(salt="littlelove.v0.2.room",
///                          ikm=shared, info=room_id_utf8, len=32)
Future<Uint8List> deriveRoomKey({
  required DerivedIdentity me,
  required Uint8List peerX25519Pub,
  required String roomId,
}) async {
  if (peerX25519Pub.length != 32) {
    throw ArgumentError(
      'peer X25519 pub must be 32 bytes, got ${peerX25519Pub.length}',
    );
  }
  final shared = await X25519().sharedSecretKey(
    keyPair: me.encryptionKeyPair,
    remotePublicKey: SimplePublicKey(
      peerX25519Pub,
      type: KeyPairType.x25519,
    ),
  );
  final sharedBytes = await shared.extractBytes();
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(sharedBytes),
    nonce: utf8.encode(_roomKeyHkdfSalt),
    info: utf8.encode(roomId),
  );
  return Uint8List.fromList(await out.extractBytes());
}
