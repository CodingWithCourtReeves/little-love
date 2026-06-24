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
      case 'Typing':
        return TypingFrame(
          roomId: json['room_id']! as String,
          from: json['from']! as String,
          typing: (json['typing'] as bool?) ?? false,
        );
      case 'Presence':
        final ls = json['last_seen'] as String?;
        return PresenceFrame(
          user: json['user']! as String,
          online: (json['online'] as bool?) ?? false,
          lastSeen: ls == null ? null : DateTime.parse(ls),
        );
      case 'Profile':
        return ProfileFrame(
          user: json['user']! as String,
          envelopeB64: json['envelope']! as String,
          avatarKey: json['avatar_key'] as String?,
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
      case 'CallTurnGrant':
        return CallTurnGrantFrame(
          callId: json['call_id']! as String,
          iceServers:
              (json['ice_servers'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{},
        );
      case 'CallInvite':
        return CallInviteFrame(
          roomId: json['room_id']! as String,
          callId: json['call_id']! as String,
          from: json['from']! as String,
          offer: json['offer']! as String,
          video: json['video'] == true,
        );
      case 'CallAnswer':
        return CallAnswerFrame(
          roomId: json['room_id']! as String,
          callId: json['call_id']! as String,
          answer: json['answer']! as String,
        );
      case 'CallIce':
        return CallIceFrame(
          roomId: json['room_id']! as String,
          callId: json['call_id']! as String,
          candidate: json['candidate']! as String,
        );
      case 'CallHangup':
        return CallHangupFrame(
          roomId: json['room_id']! as String,
          callId: json['call_id']! as String,
          reason: json['reason']! as String,
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

/// Relayed presence: [from] is composing (or stopped) in [roomId]. Transient —
/// never persisted, never replayed on subscribe.
class TypingFrame extends RoomServerFrame {
  const TypingFrame({
    required this.roomId,
    required this.from,
    required this.typing,
  });
  final String roomId;
  final String from;
  final bool typing;
}

/// Partner presence: [user] just came online or went offline. Server pushes
/// this only to the user's linked partner; never persisted.
class PresenceFrame extends RoomServerFrame {
  const PresenceFrame({
    required this.user,
    required this.online,
    this.lastSeen,
  });
  final String user;
  final bool online;

  /// The partner's last-session time, sent by the server only when [online] is
  /// false (otherwise null). UTC.
  final DateTime? lastSeen;
}

/// Relayed partner profile: [user] published a new E2EE profile. [envelopeB64]
/// is opaque ciphertext (decoded + decrypted with the pairwise room key).
class ProfileFrame extends RoomServerFrame {
  const ProfileFrame({
    required this.user,
    required this.envelopeB64,
    this.avatarKey,
  });
  final String user;
  final String envelopeB64;
  final String? avatarKey;
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

/// Short-lived ICE servers for a call, answering a [CallTurnRequestFrame].
/// [iceServers] is the raw provider object as the server passed it through —
/// `{ "iceServers": [ { "urls": .., "username": .., "credential": .. }, ... ] }`
/// (or an empty object when the relay is withheld). Not E2EE-sensitive.
class CallTurnGrantFrame extends RoomServerFrame {
  const CallTurnGrantFrame({required this.callId, required this.iceServers});
  final String callId;
  final Map<String, Object?> iceServers;
}

/// Incoming call from the partner. [offer] is the encrypted SDP offer; [from] is
/// the caller's username. Routed to the call controller (not the message router).
class CallInviteFrame extends RoomServerFrame {
  const CallInviteFrame({
    required this.roomId,
    required this.callId,
    required this.from,
    required this.offer,
    this.video = false,
  });
  final String roomId;
  final String callId;
  final String from;
  final String offer;

  /// Whether the caller started a video call (vs audio-only).
  final bool video;
}

/// The partner accepted: [answer] is the encrypted SDP answer.
class CallAnswerFrame extends RoomServerFrame {
  const CallAnswerFrame({
    required this.roomId,
    required this.callId,
    required this.answer,
  });
  final String roomId;
  final String callId;
  final String answer;
}

/// A trickled ICE candidate from the peer ([candidate] is encrypted).
class CallIceFrame extends RoomServerFrame {
  const CallIceFrame({
    required this.roomId,
    required this.callId,
    required this.candidate,
  });
  final String roomId;
  final String callId;
  final String candidate;
}

/// The peer ended/declined/cancelled the call. [reason] ∈
/// {hangup, decline, busy, timeout, cancel}.
class CallHangupFrame extends RoomServerFrame {
  const CallHangupFrame({
    required this.roomId,
    required this.callId,
    required this.reason,
  });
  final String roomId;
  final String callId;
  final String reason;
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

/// Roomless invite request (spec §5.2 / Part B). Mints an invite with
/// `room_id = NULL` and creates **no** room; the couple room is created on the
/// server only when the partner consumes. Server replies with `InviteCreated`.
class CreateInviteFrame {
  const CreateInviteFrame();

  Map<String, Object?> toJson() => <String, Object?>{'kind': 'CreateInvite'};
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
    this.tokenKind = 'alert',
  });
  final String deviceId;
  final String apnsToken;
  final String environment;

  /// `alert` (message banners) or `voip` (PushKit call wake). The wire key is
  /// `token_kind`, not `kind`, since `kind` is the frame discriminator.
  final String tokenKind;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'RegisterPush',
    'device_id': deviceId,
    'apns_token': apnsToken,
    'environment': environment,
    'token_kind': tokenKind,
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

/// Transient typing presence sent while composing. `typing:false` is sent when
/// the user stops, sends, or clears the field; a short client timeout covers a
/// dropped stop frame on the receiver.
class TypingClientFrame {
  const TypingClientFrame({required this.roomId, required this.typing});
  final String roomId;
  final bool typing;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'Typing',
    'room_id': roomId,
    'typing': typing,
  };
}

/// Ask the server to mint short-lived ICE (STUN/TURN) credentials for [callId].
/// Answered with a `CallTurnGrant` carrying the iceServers object.
class CallTurnRequestFrame {
  const CallTurnRequestFrame({required this.callId});
  final String callId;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CallTurnRequest',
    'call_id': callId,
  };
}

/// Caller → server: start a call. [offer] is the encrypted SDP offer.
class CallInviteClientFrame {
  const CallInviteClientFrame({
    required this.roomId,
    required this.callId,
    required this.offer,
    this.video = false,
  });
  final String roomId;
  final String callId;
  final String offer;

  /// Whether this is a video call (vs audio-only). Not secret — only shapes the
  /// callee's native CallKit screen on a cold wake.
  final bool video;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CallInvite',
    'room_id': roomId,
    'call_id': callId,
    'offer': offer,
    'video': video,
  };
}

/// Callee → server: accept. [answer] is the encrypted SDP answer.
class CallAnswerClientFrame {
  const CallAnswerClientFrame({
    required this.roomId,
    required this.callId,
    required this.answer,
  });
  final String roomId;
  final String callId;
  final String answer;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CallAnswer',
    'room_id': roomId,
    'call_id': callId,
    'answer': answer,
  };
}

/// Either side → server: a trickled ICE candidate ([candidate] is encrypted).
class CallIceClientFrame {
  const CallIceClientFrame({
    required this.roomId,
    required this.callId,
    required this.candidate,
  });
  final String roomId;
  final String callId;
  final String candidate;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CallIce',
    'room_id': roomId,
    'call_id': callId,
    'candidate': candidate,
  };
}

/// Either side → server: end/decline/cancel. [reason] ∈
/// {hangup, decline, busy, timeout, cancel}.
class CallHangupClientFrame {
  const CallHangupClientFrame({
    required this.roomId,
    required this.callId,
    required this.reason,
  });
  final String roomId;
  final String callId;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'CallHangup',
    'room_id': roomId,
    'call_id': callId,
    'reason': reason,
  };
}

/// Publish my E2EE profile to the server (relayed to my partner). [envelopeB64]
/// is the base64 ciphertext sealed with the pairwise room key.
class PublishProfileFrame {
  const PublishProfileFrame({required this.envelopeB64, this.avatarKey});
  final String envelopeB64;
  final String? avatarKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'PublishProfile',
    'envelope': envelopeB64,
    'avatar_key': avatarKey,
  };
}
