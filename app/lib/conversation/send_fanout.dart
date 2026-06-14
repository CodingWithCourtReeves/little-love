import 'package:uuid/uuid.dart';

import '../identity/keypair.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../wire/frames.dart';
import 'room_key_cache.dart';

/// Build the v0.3 `Send` wire frame for `plaintext` in `room`.
///
/// Per spec §6.2 each Send fans out: one ciphertext per other member,
/// addressed by recipient X25519 pubkey. The server validates the keys
/// exactly equal the other room members' pubkeys; mismatches return
/// `FanOutMismatch`.
Future<SendFrame> buildSendFrame({
  required Room room,
  required DerivedIdentity me,
  required String selfUsername,
  required String plaintext,
  required RoomKeyCache cache,
}) async {
  final bodies = <String, String>{};
  for (final m in room.members) {
    if (m.username == selfUsername) continue;
    final key = await cache.getOrDeriveFor(
      roomId: room.roomId,
      peerX25519PubBase64: m.x25519PubBase64,
      me: me,
    );
    bodies[m.x25519PubBase64] = await encryptOutgoing(key, plaintext);
  }
  return SendFrame(
    roomId: room.roomId,
    bodies: bodies,
    clientMsgId: const Uuid().v4(),
  );
}
