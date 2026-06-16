import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../crypto/ecdh.dart';
import '../identity/keypair.dart';

/// In-memory cache of pairwise AEAD keys, one per `(roomId, peer_x25519_pub)`.
/// In v0.3 each room member derives N−1 pairwise keys — one per other
/// member — so the cache key has to carry the peer pubkey, not just the
/// room id. Re-deriving is deterministic and fast (microseconds), so we
/// never persist.
class RoomKeyCache {
  final Map<String, Uint8List> _keys = {};

  String _slot(String roomId, String peerX25519PubBase64) =>
      '$roomId|$peerX25519PubBase64';

  Future<Uint8List> getOrDeriveFor({
    required String roomId,
    required String peerX25519PubBase64,
    required DerivedIdentity me,
  }) async {
    final slot = _slot(roomId, peerX25519PubBase64);
    final cached = _keys[slot];
    if (cached != null) return cached;
    final peerPub = Uint8List.fromList(base64.decode(peerX25519PubBase64));
    final key = await deriveRoomKey(
      me: me,
      peerX25519Pub: peerPub,
      roomId: roomId,
    );
    _keys[slot] = key;
    return key;
  }

  /// Drop every cached key for `roomId` (e.g., after a member leaves).
  void invalidate(String roomId) {
    _keys.removeWhere((slot, _) => slot.startsWith('$roomId|'));
  }

  void clear() => _keys.clear();
}

/// Singleton cache for the app session. Integration session wires a derived
/// identity source; widget tests construct the cache directly.
final roomKeyCacheProvider = Provider<RoomKeyCache>((_) => RoomKeyCache());
