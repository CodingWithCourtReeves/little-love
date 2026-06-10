sealed class ServerFrame {
  const ServerFrame();

  factory ServerFrame.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    switch (kind) {
      case 'Challenge':
        return ChallengeFrame(nonceBase64: json['nonce']! as String);
      case 'Authenticated':
        return const AuthenticatedFrame();
      case 'Error':
        return ErrorFrame(
          code: json['code']! as String,
          message: (json['message'] as String?) ?? '',
        );
      default:
        throw FormatException('unknown server frame kind: $kind');
    }
  }
}

class ChallengeFrame extends ServerFrame {
  const ChallengeFrame({required this.nonceBase64});
  final String nonceBase64;
}

class AuthenticatedFrame extends ServerFrame {
  const AuthenticatedFrame();
}

class ErrorFrame extends ServerFrame {
  const ErrorFrame({required this.code, required this.message});
  final String code;
  final String message;
}

class IdentifyFrame {
  IdentifyFrame({required this.username, required this.signatureBase64});
  final String username;
  final String signatureBase64;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Identify',
    'username': username,
    'signature': signatureBase64,
  };
}

/// Post-Authenticated server frames (spec §8.2). Kept as a sibling sealed
/// family rather than extending [ServerFrame] so the auth-phase exhaustive
/// switch in `auth_handshake.dart` stays valid. Auth-phase and room-phase
/// are distinct protocols on the same socket.
sealed class RoomServerFrame {
  const RoomServerFrame();

  factory RoomServerFrame.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    switch (kind) {
      case 'Rooms':
        return RoomsFrame(
          rooms: (json['rooms']! as List<dynamic>)
              .cast<Map<String, Object?>>()
              .map(RoomFramePeer.fromJson)
              .toList(growable: false),
        );
      case 'InviteCreated':
        return InviteCreatedFrame(
          code: json['code']! as String,
          qrPngBase64: json['qr_png_base64']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
        );
      case 'InviteConsumed':
        return InviteConsumedFrame(RoomFramePeer.fromJson(json));
      case 'RoomCreated':
        return RoomCreatedFrame(RoomFramePeer.fromJson(json));
      case 'Message':
        return MessageFrame(
          id: json['id']! as String,
          roomId: json['room_id']! as String,
          from: json['from']! as String,
          ts: DateTime.parse(json['ts']! as String).toUtc(),
          body: json['body']! as String,
          replayed: (json['replayed'] as bool?) ?? false,
        );
      case 'Error':
        return RoomErrorFrame(
          code: json['code']! as String,
          message: (json['message'] as String?) ?? '',
        );
      default:
        throw FormatException('unknown room server frame kind: $kind');
    }
  }
}

/// Peer-pub bundle returned by Rooms / InviteConsumed / RoomCreated (spec §8.2).
class RoomFramePeer {
  const RoomFramePeer({
    required this.roomId,
    required this.peerUsername,
    required this.peerEd25519PubBase64,
    required this.peerX25519PubBase64,
    this.createdAt,
  });

  final String roomId;
  final String peerUsername;
  final String peerEd25519PubBase64;
  final String peerX25519PubBase64;

  /// Only present in `Rooms` frames; `InviteConsumed` / `RoomCreated` omit it.
  final DateTime? createdAt;

  factory RoomFramePeer.fromJson(Map<String, Object?> json) => RoomFramePeer(
    roomId: json['room_id']! as String,
    peerUsername: json['peer_username']! as String,
    peerEd25519PubBase64: json['peer_ed25519_pub']! as String,
    peerX25519PubBase64: json['peer_x25519_pub']! as String,
    createdAt: json['created_at'] == null
        ? null
        : DateTime.parse(json['created_at']! as String).toUtc(),
  );
}

class RoomsFrame extends RoomServerFrame {
  const RoomsFrame({required this.rooms});
  final List<RoomFramePeer> rooms;
}

class InviteCreatedFrame extends RoomServerFrame {
  const InviteCreatedFrame({
    required this.code,
    required this.qrPngBase64,
    required this.expiresAt,
  });
  final String code;
  final String qrPngBase64;
  final DateTime expiresAt;
}

class InviteConsumedFrame extends RoomServerFrame {
  const InviteConsumedFrame(this.peer);
  final RoomFramePeer peer;
  String get roomId => peer.roomId;
}

class RoomCreatedFrame extends RoomServerFrame {
  const RoomCreatedFrame(this.peer);
  final RoomFramePeer peer;
  String get roomId => peer.roomId;
}

class MessageFrame extends RoomServerFrame {
  const MessageFrame({
    required this.id,
    required this.roomId,
    required this.from,
    required this.ts,
    required this.body,
    required this.replayed,
  });
  final String id;
  final String roomId;
  final String from;
  final DateTime ts;
  final String body;
  final bool replayed;
}

/// Room-phase Error frame (same shape as the auth-phase [ErrorFrame] but
/// classified into the [RoomServerFrame] family so the post-handshake
/// switch stays exhaustive).
class RoomErrorFrame extends RoomServerFrame {
  const RoomErrorFrame({required this.code, required this.message});
  final String code;
  final String message;
}

// ---------- Outbound (client → server) ----------

class CreateInviteFrame {
  const CreateInviteFrame();
  Map<String, Object?> toJson() => const {'kind': 'CreateInvite'};
}

class ConsumeInviteFrame {
  const ConsumeInviteFrame({
    required this.code,
    required this.signatureBase64,
  });
  final String code;
  final String signatureBase64;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'ConsumeInvite',
    'code': code,
    'signature_over_token': signatureBase64,
  };
}

class SubscribeFrame {
  const SubscribeFrame({required this.roomId, required this.sinceMessageId});
  final String roomId;
  final String? sinceMessageId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Subscribe',
    'room_id': roomId,
    'since_message_id': sinceMessageId,
  };
}

class SendFrame {
  const SendFrame({
    required this.roomId,
    required this.body,
    required this.clientMsgId,
  });
  final String roomId;
  final String body;
  final String clientMsgId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Send',
    'room_id': roomId,
    'body': body,
    'client_msg_id': clientMsgId,
  };
}
