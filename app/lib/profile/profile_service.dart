import '../attachment/attachment_descriptor.dart';
import '../conversation/room_key_cache.dart';
import '../identity/keypair.dart';
import '../inbox/room.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'profile_envelope.dart';
import 'profile_store.dart';

String? _peerX25519(Room room, String selfUsername) {
  for (final m in room.members) {
    if (m.username != selfUsername) return m.x25519PubBase64;
  }
  return null;
}

/// The canonical 1:1 partner room used to seal/relay profiles. The envelope key
/// is salted by room id, so the publisher and receiver MUST pick the same room.
/// Couples have exactly one unnamed 2-member DM ([RoomShape.partner]); if more
/// than one matched, the earliest-created wins so both sides agree deterministically.
Room? coupleRoomFor(Iterable<Room> rooms, String selfUsername) {
  final partners =
      rooms.where((r) => r.shape(selfUsername) == RoomShape.partner).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return partners.isEmpty ? null : partners.first;
}

/// Seal [data] with the pairwise key and send it to the server (relayed to the
/// partner). Caller has already uploaded the avatar blob and put its key on
/// [data].avatar (and passes the same blobKey as [avatarKey]). No-ops before
/// pairing (no partner to derive a key with) — the caller retries on connect.
Future<void> publishProfile({
  required LiveConnection conn,
  required Room coupleRoom,
  required DerivedIdentity me,
  required String selfUsername,
  required ProfileData data,
  required RoomKeyCache cache,
  String? avatarKey,
}) async {
  final peer = _peerX25519(coupleRoom, selfUsername);
  if (peer == null) return; // not paired yet — caller retries on next connect
  final key = await cache.getOrDeriveFor(
    roomId: coupleRoom.roomId,
    peerX25519PubBase64: peer,
    me: me,
  );
  final envelope = await encodeProfileEnvelope(key, data);
  conn.send(
    PublishProfileFrame(envelopeB64: envelope, avatarKey: avatarKey).toJson(),
  );
}

/// Assemble the local profile from already-resolved pieces and publish it to the
/// partner, picking the canonical [coupleRoomFor] room. No-ops when there is no
/// connection or no couple room yet (pre-pairing) — the caller re-runs this on
/// the next connect. Used by both the profile editor (on save) and the live
/// router (on connect, to re-assert after pairing or a reconnect).
Future<void> assembleAndPublishProfile({
  required LiveConnection? conn,
  required Iterable<Room> rooms,
  required String selfUsername,
  required String? displayName,
  required DerivedIdentity me,
  required RoomKeyCache keyCache,
  required AttachmentDescriptor? avatar,
  required String? avatarKey,
}) async {
  if (conn == null) return;
  final room = coupleRoomFor(rooms, selfUsername);
  if (room == null) return;
  await publishProfile(
    conn: conn,
    coupleRoom: room,
    me: me,
    selfUsername: selfUsername,
    data: ProfileData(displayName: displayName, avatar: avatar),
    cache: keyCache,
    avatarKey: avatarKey,
  );
}

/// Decode an inbound partner profile and apply it to [store]. Undecryptable
/// frames are dropped (the partner keeps their @username fallback).
Future<void> handleIncomingProfile(
  ProfileFrame f, {
  required Room coupleRoom,
  required DerivedIdentity me,
  required String selfUsername,
  required RoomKeyCache cache,
  required ProfileStore store,
  required DateTime receivedAt,
}) async {
  final peer = _peerX25519(coupleRoom, selfUsername);
  if (peer == null) return;
  final key = await cache.getOrDeriveFor(
    roomId: coupleRoom.roomId,
    peerX25519PubBase64: peer,
    me: me,
  );
  final data = await decodeProfileEnvelope(key, f.envelopeB64);
  if (data == null) return; // undecryptable — keep @username fallback
  store.apply(
    PartnerProfile(
      username: f.user,
      displayName: data.displayName,
      avatar: data.avatar,
      updatedAt: receivedAt,
    ),
  );
}
