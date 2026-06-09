import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptedBody {
  EncryptedBody({required this.ciphertextBase64, required this.nonceBase64});
  final String ciphertextBase64;
  final String nonceBase64;

  Map<String, Object?> toJson() => {
        'ciphertext': ciphertextBase64,
        'nonce': nonceBase64,
      };

  factory EncryptedBody.fromJson(Map<String, Object?> json) {
    return EncryptedBody(
      ciphertextBase64: json['ciphertext'] as String,
      nonceBase64: json['nonce'] as String,
    );
  }

  /// Encode the encrypted body as the single base64 string we carry
  /// in the wire-format Msg.body field, so Day-1b's String envelope
  /// keeps working unchanged.
  String toWireString() => base64.encode(utf8.encode(jsonEncode(toJson())));

  factory EncryptedBody.fromWireString(String wire) {
    final json = jsonDecode(utf8.decode(base64.decode(wire))) as Map<String, Object?>;
    return EncryptedBody.fromJson(json);
  }
}

class SymmetricCipher {
  SymmetricCipher._(this._secretKey);

  final SecretKey _secretKey;
  final _algo = Xchacha20.poly1305Aead();

  static SymmetricCipher fromHex(String hex) {
    if (hex.length != 64) {
      throw ArgumentError(
          'shared key must be 64 hex chars (32 bytes), got ${hex.length}');
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return SymmetricCipher._(SecretKey(bytes));
  }

  Future<EncryptedBody> encrypt(String plaintext) async {
    final nonce = _algo.newNonce();
    final box = await _algo.encrypt(
      utf8.encode(plaintext),
      secretKey: _secretKey,
      nonce: nonce,
    );
    // Pack ciphertext+mac as a single buffer.
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(box.cipherText.length,
          box.cipherText.length + box.mac.bytes.length, box.mac.bytes);
    return EncryptedBody(
      ciphertextBase64: base64.encode(out),
      nonceBase64: base64.encode(nonce),
    );
  }

  Future<String> decrypt(EncryptedBody env) async {
    final raw = base64.decode(env.ciphertextBase64);
    if (raw.length < 16) {
      throw const FormatException('ciphertext too short to contain MAC');
    }
    final cipherText = raw.sublist(0, raw.length - 16);
    final mac = Mac(raw.sublist(raw.length - 16));
    final nonce = base64.decode(env.nonceBase64);
    final plain = await _algo.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: _secretKey,
    );
    return utf8.decode(plain);
  }
}
