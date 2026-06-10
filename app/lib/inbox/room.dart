import 'package:flutter/foundation.dart';

/// A couples-chat room, as exposed to the client. Field names mirror the
/// spec §8.2 `Rooms` / `RoomCreated` / `InviteConsumed` wire-frame shape so
/// WT-D's WSS frame parsers can deserialise straight into this type.
@immutable
class Room {
  const Room({
    required this.roomId,
    required this.peerUsername,
    required this.peerEd25519PubBase64,
    required this.peerX25519PubBase64,
    required this.createdAt,
  });

  /// ULID, server-issued (spec §8.4 `rooms.id`).
  final String roomId;
  final String peerUsername;
  final String peerEd25519PubBase64;
  final String peerX25519PubBase64;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Room &&
          other.roomId == roomId &&
          other.peerUsername == peerUsername &&
          other.peerEd25519PubBase64 == peerEd25519PubBase64 &&
          other.peerX25519PubBase64 == peerX25519PubBase64 &&
          other.createdAt == createdAt);

  @override
  int get hashCode => Object.hash(
    roomId,
    peerUsername,
    peerEd25519PubBase64,
    peerX25519PubBase64,
    createdAt,
  );

  @override
  String toString() => 'Room(roomId: $roomId, peerUsername: $peerUsername)';
}
