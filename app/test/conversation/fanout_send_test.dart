import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/conversation/send_fanout.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Future<DerivedIdentity> _identityFromByte(int b) =>
    derivedIdentityFromSigningSeedForTest(
      Uint8List.fromList(List.filled(32, b)),
    );

Member memberOf(DerivedIdentity id, String username, {bool bot = false}) =>
    Member(
      username: username,
      ed25519PubBase64: base64.encode(id.ed25519PublicKey),
      x25519PubBase64: base64.encode(id.x25519PublicKey),
      isBot: bot,
    );

void main() {
  test('encrypts one ciphertext per other member plus a self-copy', () async {
    final me = await _identityFromByte(11);
    final partner = await _identityFromByte(12);
    final bot = await _identityFromByte(13);

    final room = Room(
      roomId: 'r1',
      name: '',
      members: [
        memberOf(me, 'court'),
        memberOf(partner, 'kaitlyn'),
        memberOf(bot, 'court-garden', bot: true),
      ],
      createdAt: DateTime.utc(2026, 6, 10),
    );

    final cache = RoomKeyCache();
    final frame = await buildSendFrame(
      room: room,
      me: me,
      selfUsername: 'court',
      plaintext: 'hello',
      cache: cache,
    );

    expect(frame.roomId, 'r1');
    // Two other members + a copy addressed to ourselves.
    expect(frame.bodies.length, 3);
    expect(frame.bodies.keys.toSet(), {
      base64.encode(partner.x25519PublicKey),
      base64.encode(bot.x25519PublicKey),
      base64.encode(me.x25519PublicKey),
    });
    // Ciphertexts differ per recipient (distinct keys, including self).
    final cts = frame.bodies.values.toSet();
    expect(cts.length, 3);
  });

  test('solo room (self only) still produces a self-copy', () async {
    final me = await _identityFromByte(20);
    final room = Room(
      roomId: 'r2',
      name: '',
      members: [memberOf(me, 'court')],
      createdAt: DateTime.utc(2026, 6, 10),
    );
    final frame = await buildSendFrame(
      room: room,
      me: me,
      selfUsername: 'court',
      plaintext: 'whispered to no one',
      cache: RoomKeyCache(),
    );
    expect(frame.bodies.keys.toSet(), {base64.encode(me.x25519PublicKey)});
  });
}
