import 'dart:convert';
import 'dart:io';

import '../attachment/attachment_descriptor.dart';
import '../attachment/attachment_upload.dart';
import '../attachment/file_crypto.dart';
import '../attachment/thumbnail.dart';
import '../conversation/room_key_cache.dart';
import '../identity/keypair.dart';
import '../inbox/room.dart';
import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'profile_envelope.dart';
import 'profile_publish_cache.dart';
import 'profile_store.dart';

String? _peerX25519(Room room, String selfUsername) {
  for (final m in room.members) {
    if (m.username != selfUsername) return m.x25519PubBase64;
  }
  return null;
}

/// The canonical room used to seal/relay profiles. The envelope key is salted by
/// room id, so the publisher and receiver MUST pick the same room. This app is
/// couples-only — every room is the same two people — so ANY room shared with
/// the partner works; we pick the lowest `roomId` (server-assigned, identical on
/// both devices) so both sides deterministically agree. Crucially this does NOT
/// require an unnamed DM: a couple whose only rooms are named channels still
/// syncs profiles. Returns null only when no room is shared with a partner yet.
Room? coupleRoomFor(Iterable<Room> rooms, String selfUsername) {
  final shared =
      rooms
          .where(
            (r) =>
                r.members.where((m) => m.username != selfUsername).length == 1,
          )
          .toList()
        ..sort((a, b) => a.roomId.compareTo(b.roomId));
  return shared.isEmpty ? null : shared.first;
}

/// Ensure the local avatar is uploaded to the blob store, returning its
/// descriptor. Returns the cached descriptor when the photo was already
/// uploaded (so a reconnect re-asserts without re-uploading); otherwise reads
/// [avatarPath], encrypts, uploads to [room], caches the result, and returns it.
/// Returns null when there's no local avatar. Throws if the upload fails — the
/// caller treats that as best-effort and retries on the next connect. To force a
/// re-upload after picking a NEW photo, clear the cache first
/// (`cache.setAvatar(null, null)`).
Future<AttachmentDescriptor?> ensureAvatarUploaded({
  required LiveConnection conn,
  required Room room,
  required String? avatarPath,
  required ProfilePublishCache cache,
}) async {
  final cached = await cache.avatar();
  if (cached != null) return cached;
  if (avatarPath == null) return null;
  final file = File(avatarPath);
  if (!file.existsSync()) return null;
  final bytes = await file.readAsBytes();
  final enc = await encryptFileBytes(bytes);
  final blobKey = await uploadCiphertext(
    conn: conn,
    roomId: room.roomId,
    ciphertext: enc.ciphertext,
  );
  final thumb = await buildImageThumbnail(
    bytes,
    maxEdge: 128,
    maxThumbBytes: 12 * 1024,
  );
  final descriptor = AttachmentDescriptor(
    blobKey: blobKey,
    contentKeyB64: base64.encode(enc.key),
    nonceB64: base64.encode(enc.nonce),
    mime: 'image/jpeg',
    filename: 'avatar.jpg',
    size: bytes.length,
    width: thumb.width,
    height: thumb.height,
    durationMs: null,
    thumbB64: base64.encode(thumb.jpeg),
  );
  await cache.setAvatar(descriptor, blobKey);
  return descriptor;
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
