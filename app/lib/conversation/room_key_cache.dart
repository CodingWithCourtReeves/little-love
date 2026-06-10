import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/ecdh.dart';
import '../identity/keypair.dart';
import '../inbox/room.dart';

/// In-memory cache of per-room AEAD keys. The room key is deterministic
/// from `(my_x25519_priv, peer_x25519_pub, room_id)`, so we never persist —
/// re-deriving from cached pubkeys + the identity is microseconds. Spec §5.3.
class RoomKeyCache {
  final Map<String, Uint8List> _keys = {};

  Future<Uint8List> getOrDerive(Room peer, DerivedIdentity me) async {
    final cached = _keys[peer.roomId];
    if (cached != null) return cached;
    final peerPub = Uint8List.fromList(base64.decode(peer.peerX25519PubBase64));
    final key = await deriveRoomKey(
      me: me,
      peerX25519Pub: peerPub,
      roomId: peer.roomId,
    );
    _keys[peer.roomId] = key;
    return key;
  }

  void invalidate(String roomId) => _keys.remove(roomId);

  void clear() => _keys.clear();
}

/// Singleton cache for the app session. Integration session wires a derived
/// identity source; widget tests construct the cache directly.
final roomKeyCacheProvider = Provider<RoomKeyCache>((_) => RoomKeyCache());
