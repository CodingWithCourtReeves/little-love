import 'package:uuid/uuid.dart';

import '../identity/keypair.dart';
import '../inbox/room.dart';
import '../pairing/encryption.dart';
import '../wire/frames.dart';
import 'room_key_cache.dart';

/// Build the v0.3 `Send` wire frame for `plaintext` in `room`.
///
/// Per spec §6.2 each Send fans out one ciphertext per other member, addressed
/// by recipient X25519 pubkey. We additionally include a copy addressed to the
/// sender's own key (encrypted via ECDH with our own keypair) so the server
/// stores the message for us too — this is what lets our own sent messages
/// survive an app restart (the server is the source of truth, same as for
/// every recipient). This mirrors Signal-style client fan-out, where the
/// sender also fans a copy out to their own devices. The server validates the
/// provided keys equal the other members' pubkeys, optionally plus our own.
Future<SendFrame> buildSendFrame({
  required Room room,
  required DerivedIdentity me,
  required String selfUsername,
  required String plaintext,
  required RoomKeyCache cache,
  String? clientMsgId,
}) async {
  final bodies = <String, String>{};
  String? selfX25519;
  for (final m in room.members) {
    if (m.username == selfUsername) {
      selfX25519 = m.x25519PubBase64;
      continue;
    }
    final key = await cache.getOrDeriveFor(
      roomId: room.roomId,
      peerX25519PubBase64: m.x25519PubBase64,
      me: me,
    );
    bodies[m.x25519PubBase64] = await encryptOutgoing(key, plaintext);
  }
  if (selfX25519 != null) {
    final selfKey = await cache.getOrDeriveFor(
      roomId: room.roomId,
      peerX25519PubBase64: selfX25519,
      me: me,
    );
    bodies[selfX25519] = await encryptOutgoing(selfKey, plaintext);
  }
  return SendFrame(
    roomId: room.roomId,
    bodies: bodies,
    clientMsgId: clientMsgId ?? const Uuid().v4(),
  );
}
