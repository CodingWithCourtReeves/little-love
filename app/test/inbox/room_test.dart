import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/room.dart';

void main() {
  test('Room equality is structural', () {
    final a = Room(
      roomId: '01J',
      peerUsername: 'kaitlyn',
      peerEd25519PubBase64: 'AAA',
      peerX25519PubBase64: 'BBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    final b = Room(
      roomId: '01J',
      peerUsername: 'kaitlyn',
      peerEd25519PubBase64: 'AAA',
      peerX25519PubBase64: 'BBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('Rooms with different ids are unequal', () {
    final a = Room(
      roomId: '01J',
      peerUsername: 'kaitlyn',
      peerEd25519PubBase64: 'AAA',
      peerX25519PubBase64: 'BBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    final b = Room(
      roomId: '01K',
      peerUsername: 'kaitlyn',
      peerEd25519PubBase64: 'AAA',
      peerX25519PubBase64: 'BBB',
      createdAt: DateTime.utc(2026, 6, 9),
    );
    expect(a, isNot(equals(b)));
  });
}
