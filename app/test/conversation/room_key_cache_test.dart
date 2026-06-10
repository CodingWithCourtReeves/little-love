import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';

Room _peerRoom(String id, Uint8List peerX25519Pub) => Room(
      roomId: id,
      peerUsername: 'kaitlyn',
      peerEd25519PubBase64: base64.encode(Uint8List(32)),
      peerX25519PubBase64: base64.encode(peerX25519Pub),
      createdAt: DateTime.utc(2026, 6, 9),
    );

void main() {
  group('RoomKeyCache', () {
    test('getOrDerive caches by roomId — second call uses cache', () async {
      final a = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x11),
      );
      final b = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x22),
      );
      final cache = RoomKeyCache();
      final room = _peerRoom('room-1', b.x25519PublicKey);

      final first = await cache.getOrDerive(room, a);
      final second = await cache.getOrDerive(room, a);
      expect(
        identical(first, second),
        isTrue,
        reason: 'cache must hand back the same Uint8List instance',
      );
    });

    test('distinct rooms get distinct keys', () async {
      final a = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x11),
      );
      final b = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x22),
      );
      final cache = RoomKeyCache();
      final r1 = _peerRoom('room-1', b.x25519PublicKey);
      final r2 = _peerRoom('room-2', b.x25519PublicKey);
      final k1 = await cache.getOrDerive(r1, a);
      final k2 = await cache.getOrDerive(r2, a);
      expect(k1, isNot(equals(k2)));
    });

    test('invalidate drops the cached key', () async {
      final a = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x11),
      );
      final b = await derivedIdentityFromSigningSeedForTest(
        Uint8List(32)..fillRange(0, 32, 0x22),
      );
      final cache = RoomKeyCache();
      final room = _peerRoom('room-1', b.x25519PublicKey);
      final first = await cache.getOrDerive(room, a);
      cache.invalidate('room-1');
      final second = await cache.getOrDerive(room, a);
      expect(first, second);
      expect(identical(first, second), isFalse);
    });
  });
}
