import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../pairing/encryption.dart';

/// Domain-separation salt for the per-call signaling sub-key. Pinned — a change
/// is a wire-incompat protocol bump. Mirrors the spec (§2.2) and keeps call
/// signaling ciphertext cryptographically separate from message traffic.
const _callSigHkdfSalt = 'littlelove.v0.2.call-sig';

/// Derive the per-call signaling key from the shared room key:
///   sig_key = HKDF-SHA256(salt="littlelove.v0.2.call-sig",
///                         ikm=room_key, info=call_id, len=32)
///
/// Both partners derive the same key (they share the room key); the server
/// never does — it forwards the resulting ciphertext blind. A fresh `call_id`
/// yields a fresh key per call.
Future<Uint8List> deriveSigKey(Uint8List roomKey, String callId) async {
  if (roomKey.length != 32) {
    throw ArgumentError('room key must be 32 bytes, got ${roomKey.length}');
  }
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(roomKey),
    nonce: utf8.encode(_callSigHkdfSalt),
    info: utf8.encode(callId),
  );
  return Uint8List.fromList(await out.extractBytes());
}

/// Encrypt an SDP or ICE-candidate payload under the per-call [sigKey],
/// returning the base64-of-JSON wire string. Reuses the message AEAD envelope
/// (XChaCha20-Poly1305).
Future<String> encryptSignal(Uint8List sigKey, String plaintext) =>
    encryptOutgoing(sigKey, plaintext);

/// Decrypt a signaling wire string under [sigKey]. Returns
/// [cannotDecryptSentinel] on any AEAD failure — a forged or tampered frame
/// (wrong key, wrong call) simply won't decrypt, which is the anti-MITM
/// guarantee for the SDP/DTLS-fingerprint exchange.
Future<String> decryptSignal(Uint8List sigKey, String wire) =>
    decryptIncoming(sigKey, wire);
