// Auth-phase frames (spec §3.3). These travel before Authenticated.

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

// ---------- Shared payload types (spec §8.2 v0.3) ----------

/// One participant of a room. Same shape used by `Rooms`, `RoomCreated`,
/// `InviteConsumed` payloads.
class Member {
  const Member({
    required this.username,
    required this.ed25519PubBase64,
    required this.x25519PubBase64,
    this.accountId,
  });

  /// Server-assigned account id. Null when the server omits it.
  final int? accountId;
  final String username;
  final String ed25519PubBase64;
  final String x25519PubBase64;

  factory Member.fromJson(Map<String, Object?> j) => Member(
    accountId: (j['account_id'] as num?)?.toInt(),
    username: j['username']! as String,
    ed25519PubBase64: j['ed25519_pub']! as String,
    x25519PubBase64: j['x25519_pub']! as String,
  );
}

/// A room as the server sees it: id, optional display name, full roster,
/// creation timestamp. Inlined into `Rooms` / `RoomCreated` /
/// `InviteConsumed` frames.
class RoomDetail {
  const RoomDetail({
    required this.roomId,
    required this.name,
    required this.members,
    required this.createdAt,
  });

  final String roomId;
  final String name;
  final List<Member> members;
  final DateTime createdAt;

  factory RoomDetail.fromJson(Map<String, Object?> j) => RoomDetail(
    roomId: j['room_id']! as String,
    name: (j['name'] as String?) ?? '',
    members: (j['members']! as List<dynamic>)
        .cast<Map<String, Object?>>()
        .map(Member.fromJson)
        .toList(growable: false),
    createdAt: DateTime.parse(j['created_at']! as String).toUtc(),
  );
}

/// Pending invite returned inline with `RoomCreated` when the creator asked
/// to invite their human partner alongside room creation.
class PendingInvite {
  const PendingInvite({
    required this.code,
    required this.qrPngBase64,
    required this.expiresAt,
  });

  final String code;
  final String qrPngBase64;
  final DateTime expiresAt;

  factory PendingInvite.fromJson(Map<String, Object?> j) => PendingInvite(
    code: j['code']! as String,
    qrPngBase64: (j['qr_png_base64'] as String?) ?? '',
    expiresAt: DateTime.parse(j['expires_at']! as String).toUtc(),
  );
}

// ---------- Post-Authenticated server → client frames (spec §8.2) ----------

sealed class RoomServerFrame {
  const RoomServerFrame();

  factory RoomServerFrame.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    switch (kind) {
      case 'Rooms':
        return RoomsFrame(
          rooms: (json['rooms']! as List<dynamic>)
              .cast<Map<String, Object?>>()
              .map(RoomDetail.fromJson)
              .toList(growable: false),
        );
      case 'InviteCreated':
        return InviteCreatedFrame(
          code: json['code']! as String,
          qrPngBase64: json['qr_png_base64']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
        );
      case 'InviteConsumed':
        return InviteConsumedFrame(
          roomId: json['room_id']! as String,
          name: (json['name'] as String?) ?? '',
          members: (json['members']! as List<dynamic>)
              .cast<Map<String, Object?>>()
              .map(Member.fromJson)
              .toList(growable: false),
        );
      case 'RoomCreated':
        return RoomCreatedFrame(
          roomId: json['room_id']! as String,
          name: (json['name'] as String?) ?? '',
          members: (json['members']! as List<dynamic>)
              .cast<Map<String, Object?>>()
              .map(Member.fromJson)
              .toList(growable: false),
          pendingInvite: json['pending_invite'] == null
              ? null
              : PendingInvite.fromJson(
                  json['pending_invite']! as Map<String, Object?>,
                ),
        );
      case 'RoomRenamed':
        return RoomRenamedFrame(
          roomId: json['room_id']! as String,
          name: json['name']! as String,
        );
      case 'MemberLeft':
        return MemberLeftFrame(
          roomId: json['room_id']! as String,
          username: json['username']! as String,
        );
      case 'Message':
        return MessageFrame(
          id: json['id']! as String,
          roomId: json['room_id']! as String,
          from: json['from']! as String,
          ts: DateTime.parse(json['ts']! as String).toUtc(),
          body: json['body']! as String,
          replayed: (json['replayed'] as bool?) ?? false,
          read: (json['read'] as bool?) ?? false,
          clientMsgId: json['client_msg_id'] as String?,
        );
      case 'Read':
        return ReadFrame(
          roomId: json['room_id']! as String,
          messageIds: (json['message_ids']! as List<dynamic>).cast<String>(),
          reader: json['reader']! as String,
        );
      case 'UploadGranted':
        return UploadGrantedFrame(
          requestId: json['request_id']! as String,
          blobKey: json['blob_key']! as String,
          url: json['url']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
        );
      case 'DownloadGranted':
        return DownloadGrantedFrame(
          blobKey: json['blob_key']! as String,
          url: json['url']! as String,
          expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
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

class RoomsFrame extends RoomServerFrame {
  const RoomsFrame({required this.rooms});
  final List<RoomDetail> rooms;
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
  const InviteConsumedFrame({
    required this.roomId,
    required this.name,
    required this.members,
  });
  final String roomId;
  final String name;
  final List<Member> members;
}

class RoomCreatedFrame extends RoomServerFrame {
  const RoomCreatedFrame({
    required this.roomId,
    required this.name,
    required this.members,
    required this.pendingInvite,
  });
  final String roomId;
  final String name;
  final List<Member> members;
  final PendingInvite? pendingInvite;
}

class RoomRenamedFrame extends RoomServerFrame {
  const RoomRenamedFrame({required this.roomId, required this.name});
  final String roomId;
  final String name;
}

class MemberLeftFrame extends RoomServerFrame {
  const MemberLeftFrame({required this.roomId, required this.username});
  final String roomId;
  final String username;
}

class MessageFrame extends RoomServerFrame {
  const MessageFrame({
    required this.id,
    required this.roomId,
    required this.from,
    required this.ts,
    required this.body,
    required this.replayed,
    this.read = false,
    this.clientMsgId,
  });
  final String id;
  final String roomId;
  final String from;
  final DateTime ts;

  /// Single ciphertext addressed to this recipient (spec §6.2 — the server
  /// fans out one row per recipient and each session only ever sees its
  /// own addressed body).
  final String body;
  final bool replayed;

  /// True on the sender's own self-copy once the partner has read it. Set on
  /// `Subscribe` replay so double hearts survive a restart; false otherwise.
  final bool read;

  /// Present only on the sender's own live self-copy: the `clientMsgId` of the
  /// originating `SendFrame`. Lets the sending session reconcile its optimistic
  /// local echo (keyed by this id) with the authoritative server row. Null for
  /// messages from others and for replayed history.
  final String? clientMsgId;
}

/// Relayed to a sender when the partner reads one or more of their messages.
class ReadFrame extends RoomServerFrame {
  const ReadFrame({
    required this.roomId,
    required this.messageIds,
    required this.reader,
  });
  final String roomId;
  final List<String> messageIds;
  final String reader;
}

class RoomErrorFrame extends RoomServerFrame {
  const RoomErrorFrame({required this.code, required this.message});
  final String code;
  final String message;
}

class UploadGrantedFrame extends RoomServerFrame {
  const UploadGrantedFrame({
    required this.requestId,
    required this.blobKey,
    required this.url,
    required this.expiresAt,
  });
  final String requestId;
  final String blobKey;
  final String url;
  final DateTime expiresAt;
}

class DownloadGrantedFrame extends RoomServerFrame {
  const DownloadGrantedFrame({
    required this.blobKey,
    required this.url,
    required this.expiresAt,
  });
  final String blobKey;
  final String url;
  final DateTime expiresAt;
}

// ---------- Outbound (client → server) ----------

class ConsumeInviteFrame {
  const ConsumeInviteFrame({required this.code, required this.signatureBase64});
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
    required this.bodies,
    required this.clientMsgId,
  });
  final String roomId;

  /// Map from recipient `x25519_pub_b64` to the addressed ciphertext.
  final Map<String, String> bodies;
  final String clientMsgId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Send',
    'room_id': roomId,
    'bodies': bodies,
    'client_msg_id': clientMsgId,
  };
}

/// Sent when the client opens a chat: acknowledges every message in the room
/// up to and including [upToMessageId] as read.
class MarkReadFrame {
  const MarkReadFrame({required this.roomId, required this.upToMessageId});
  final String roomId;
  final String upToMessageId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'MarkRead',
    'room_id': roomId,
    'up_to_message_id': upToMessageId,
  };
}

class CreateRoomFrame {
  const CreateRoomFrame({this.name, required this.inviteHumanPartner});
  final String? name;
  final bool inviteHumanPartner;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CreateRoom',
    'name': name,
    'invite_human_partner': inviteHumanPartner,
  };
}

class RenameRoomFrame {
  const RenameRoomFrame({required this.roomId, required this.name});
  final String roomId;
  final String name;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RenameRoom',
    'room_id': roomId,
    'name': name,
  };
}

class LeaveRoomFrame {
  const LeaveRoomFrame({required this.roomId});
  final String roomId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'LeaveRoom',
    'room_id': roomId,
  };
}

class RequestUploadFrame {
  const RequestUploadFrame({
    required this.requestId,
    required this.roomId,
    required this.byteSize,
  });
  final String requestId;
  final String roomId;
  final int byteSize;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RequestUpload',
    'request_id': requestId,
    'room_id': roomId,
    'byte_size': byteSize,
  };
}

class RequestDownloadFrame {
  const RequestDownloadFrame({required this.blobKey});
  final String blobKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RequestDownload',
    'blob_key': blobKey,
  };
}

class RegisterPushFrame {
  const RegisterPushFrame({
    required this.deviceId,
    required this.apnsToken,
    required this.environment,
  });
  final String deviceId;
  final String apnsToken;
  final String environment;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RegisterPush',
    'device_id': deviceId,
    'apns_token': apnsToken,
    'environment': environment,
  };
}

class UnregisterPushFrame {
  const UnregisterPushFrame({required this.deviceId});
  final String deviceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'UnregisterPush',
    'device_id': deviceId,
  };
}
