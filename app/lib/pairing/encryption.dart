import 'dart:typed_data';

import '../crypto/cipher.dart';

/// Sentinel returned by [decryptIncoming] when the AEAD body is undecryptable.
/// Callers render "could not decrypt" UI when they see this value. Pinned as
/// a public const so widget tests don't hardcode the literal.
const String cannotDecryptSentinel = '__cannot_decrypt__';

/// Spec §5.2: XChaCha20-Poly1305 over the plaintext. The output is the same
/// base64-of-JSON wire-body string Day-1c established.
Future<String> encryptOutgoing(Uint8List roomKey, String plaintext) async {
  final cipher = SymmetricCipher.fromHex(_hexOf(roomKey));
  final body = await cipher.encrypt(plaintext);
  return body.toWireString();
}

/// Spec §13 AC #3: decrypt and on any AEAD failure return
/// [cannotDecryptSentinel].
Future<String> decryptIncoming(Uint8List roomKey, String wireBody) async {
  try {
    final cipher = SymmetricCipher.fromHex(_hexOf(roomKey));
    final env = EncryptedBody.fromWireString(wireBody);
    return await cipher.decrypt(env);
  } catch (_) {
    return cannotDecryptSentinel;
  }
}

String _hexOf(Uint8List bytes) {
  if (bytes.length != 32) {
    throw ArgumentError('room key must be 32 bytes, got ${bytes.length}');
  }
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
