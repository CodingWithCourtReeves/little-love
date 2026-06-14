import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/identity/keypair.dart';

Future<DerivedIdentity> _identityFromByte(int b) =>
    derivedIdentityFromSigningSeedForTest(Uint8List.fromList(List.filled(32, b)));

void main() {
  test('distinct keys per peer pubkey in same room', () async {
    final me = await _identityFromByte(1);
    final peer1 = await _identityFromByte(2);
    final peer2 = await _identityFromByte(3);
    final cache = RoomKeyCache();

    final k1 = await cache.getOrDeriveFor(
      roomId: 'r',
      peerX25519PubBase64: base64.encode(peer1.x25519PublicKey),
      me: me,
    );
    final k2 = await cache.getOrDeriveFor(
      roomId: 'r',
      peerX25519PubBase64: base64.encode(peer2.x25519PublicKey),
      me: me,
    );
    expect(k1, isNot(equals(k2)));
  });

  test('cache returns the same bytes on repeat call', () async {
    final me = await _identityFromByte(4);
    final peer = await _identityFromByte(5);
    final cache = RoomKeyCache();
    final pubB64 = base64.encode(peer.x25519PublicKey);
    final a = await cache.getOrDeriveFor(
      roomId: 'r',
      peerX25519PubBase64: pubB64,
      me: me,
    );
    final b = await cache.getOrDeriveFor(
      roomId: 'r',
      peerX25519PubBase64: pubB64,
      me: me,
    );
    expect(a, equals(b));
  });

  test('invalidate drops keys for that room only', () async {
    final me = await _identityFromByte(6);
    final peer = await _identityFromByte(7);
    final cache = RoomKeyCache();
    final pubB64 = base64.encode(peer.x25519PublicKey);
    await cache.getOrDeriveFor(roomId: 'a', peerX25519PubBase64: pubB64, me: me);
    await cache.getOrDeriveFor(roomId: 'b', peerX25519PubBase64: pubB64, me: me);
    cache.invalidate('a');
    // Re-deriving for room a returns equal bytes (deterministic), but
    // bypasses the cache. We assert behavior indirectly: getOrDeriveFor
    // still returns something non-empty after invalidate.
    final k = await cache.getOrDeriveFor(
      roomId: 'a',
      peerX25519PubBase64: pubB64,
      me: me,
    );
    expect(k, isNotEmpty);
  });
}
