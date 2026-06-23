import 'dart:convert';
import 'dart:typed_data';

import '../attachment/attachment_descriptor.dart';
import '../pairing/encryption.dart';

/// The decrypted contents of a profile envelope.
class ProfileData {
  const ProfileData({required this.displayName, required this.avatar});
  final String? displayName;
  final AttachmentDescriptor? avatar;
}

Map<String, Object?> _toPlain(ProfileData d) => <String, Object?>{
  'display_name': d.displayName,
  'avatar': d.avatar?.toJson(),
};

/// Seal [data] with the pairwise [roomKey]; returns base64 for the wire.
Future<String> encodeProfileEnvelope(Uint8List roomKey, ProfileData data) async {
  final wire = await encryptOutgoing(roomKey, jsonEncode(_toPlain(data)));
  return base64.encode(utf8.encode(wire));
}

/// Inverse of [encodeProfileEnvelope]. Returns null when undecryptable
/// (wrong/rotated key or corrupt frame) — callers fall back to @username.
Future<ProfileData?> decodeProfileEnvelope(
  Uint8List roomKey,
  String envelopeB64,
) async {
  final String wire;
  try {
    wire = utf8.decode(base64.decode(envelopeB64));
  } catch (_) {
    return null;
  }
  final plain = await decryptIncoming(roomKey, wire);
  if (plain == cannotDecryptSentinel) return null;
  final Map<String, Object?> map;
  try {
    map = jsonDecode(plain) as Map<String, Object?>;
  } catch (_) {
    return null;
  }
  final avatarJson = map['avatar'] as Map<String, Object?>?;
  return ProfileData(
    displayName: map['display_name'] as String?,
    avatar: avatarJson == null
        ? null
        : AttachmentDescriptor.fromJson(avatarJson),
  );
}
