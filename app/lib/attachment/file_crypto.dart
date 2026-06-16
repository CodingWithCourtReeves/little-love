import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Result of encrypting a file's bytes: the random per-file [key] and [nonce]
/// (which go into the message envelope, encrypted per-recipient) plus the
/// [ciphertext] (which is uploaded raw to R2). XChaCha20-Poly1305 — same AEAD
/// as text messages (spec §4).
class EncryptedFile {
  EncryptedFile({required this.key, required this.nonce, required this.ciphertext});
  final Uint8List key;
  final Uint8List nonce;
  final Uint8List ciphertext;
}

final _algo = Xchacha20.poly1305Aead();

Future<EncryptedFile> encryptFileBytes(Uint8List plain) async {
  final secret = await _algo.newSecretKey();
  final nonce = _algo.newNonce();
  final box = await _algo.encrypt(plain, secretKey: secret, nonce: nonce);
  final keyBytes = Uint8List.fromList(await secret.extractBytes());
  final out = Uint8List(box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, box.cipherText.length, box.cipherText)
    ..setRange(box.cipherText.length, box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
  return EncryptedFile(
    key: keyBytes,
    nonce: Uint8List.fromList(nonce),
    ciphertext: out,
  );
}

Future<Uint8List> decryptFileBytes({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List ciphertext,
}) async {
  if (ciphertext.length < 16) {
    throw const FormatException('ciphertext too short to contain MAC');
  }
  final ct = ciphertext.sublist(0, ciphertext.length - 16);
  final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
  final plain = await _algo.decrypt(
    SecretBox(ct, nonce: nonce, mac: mac),
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(plain);
}

Uint8List base64ToBytes(String b64) => base64.decode(b64);
