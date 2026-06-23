import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/room_key_cache.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/profile/profile_envelope.dart';
import 'package:littlelove/profile/profile_service.dart';
import 'package:littlelove/profile/profile_store.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

Future<DerivedIdentity> _identityFromByte(int b) =>
    derivedIdentityFromSigningSeedForTest(
      Uint8List.fromList(List.filled(32, b)),
    );

Member _memberOf(DerivedIdentity id, String username) => Member(
  username: username,
  ed25519PubBase64: base64.encode(id.ed25519PublicKey),
  x25519PubBase64: base64.encode(id.x25519PublicKey),
);

/// Captures the frames sent through it; never receives.
class _FakeConn implements LiveConnection {
  final List<Object> sent = [];
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Stream<RoomServerFrame> get incoming => const Stream.empty();
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async {}
}

void main() {
  test('publish then handle reproduces display name in the store', () async {
    final alice = await _identityFromByte(11);
    final bob = await _identityFromByte(12);
    final room = Room(
      roomId: 'r1',
      name: '',
      members: [_memberOf(alice, 'alice'), _memberOf(bob, 'bob')],
      createdAt: DateTime.utc(2026, 6, 10),
    );

    // Alice publishes her profile.
    final conn = _FakeConn();
    await publishProfile(
      conn: conn,
      coupleRoom: room,
      me: alice,
      selfUsername: 'alice',
      data: const ProfileData(displayName: 'Ali', avatar: null),
      cache: RoomKeyCache(),
      avatarKey: null,
    );

    expect(conn.sent, hasLength(1));
    final payload = conn.sent.single as Map<String, Object?>;
    expect(payload['kind'], 'PublishProfile');
    final envelope = payload['envelope']! as String;

    // Bob receives it as a Profile frame and decodes it with his own identity.
    final frame = ProfileFrame(user: 'alice', envelopeB64: envelope);
    final store = ProfileStore();
    await handleIncomingProfile(
      frame,
      coupleRoom: room,
      me: bob,
      selfUsername: 'bob',
      cache: RoomKeyCache(),
      store: store,
      receivedAt: DateTime.utc(2026, 6, 10),
    );

    expect(store.forUsername('alice')!.displayName, 'Ali');
  });

  test('publish is a no-op in a solo (unpaired) room', () async {
    final alice = await _identityFromByte(20);
    final room = Room(
      roomId: 'r2',
      name: '',
      members: [_memberOf(alice, 'alice')],
      createdAt: DateTime.utc(2026, 6, 10),
    );
    final conn = _FakeConn();
    await publishProfile(
      conn: conn,
      coupleRoom: room,
      me: alice,
      selfUsername: 'alice',
      data: const ProfileData(displayName: 'Ali', avatar: null),
      cache: RoomKeyCache(),
    );
    expect(conn.sent, isEmpty);
  });

  group('coupleRoomFor', () {
    Room room(String id, String name, List<String> usernames) => Room(
      roomId: id,
      name: name,
      members: [
        for (final u in usernames)
          Member(username: u, ed25519PubBase64: 'e', x25519PubBase64: 'x-$u'),
      ],
      createdAt: DateTime.utc(2026, 6, 10),
    );

    test('picks a shared room even when it is a NAMED channel (no DM)', () {
      // The couple renamed their DM away; only named channels remain.
      final rooms = [
        room('01B-date', 'date-ideas', ['court', 'kaitlyn']),
        room('01A-info', 'info', ['court', 'kaitlyn']),
      ];
      // Lowest roomId wins, deterministically, regardless of name.
      expect(coupleRoomFor(rooms, 'court')!.roomId, '01A-info');
    });

    test('agrees across both partners (same room id from either side)', () {
      final rooms = [
        room('01A-info', 'info', ['court', 'kaitlyn']),
        room('01B-date', 'date-ideas', ['court', 'kaitlyn']),
      ];
      expect(
        coupleRoomFor(rooms, 'court')!.roomId,
        coupleRoomFor(rooms, 'kaitlyn')!.roomId,
      );
    });

    test('null when no room is shared with a partner', () {
      final rooms = [
        room('01A-solo', '', ['court']),
      ];
      expect(coupleRoomFor(rooms, 'court'), isNull);
    });
  });
}
