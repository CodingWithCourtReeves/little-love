import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

List<Member> _members(String peer) => [
  const Member(username: 'court', ed25519PubBase64: '', x25519PubBase64: ''),
  Member(username: peer, ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
];

void main() {
  test('Room equality is structural', () {
    final a = Room(
      roomId: '01J',
      name: '',
      members: _members('kaitlyn'),
      createdAt: DateTime.utc(2026, 6, 9),
    );
    final b = Room(
      roomId: '01J',
      name: '',
      members: _members('kaitlyn'),
      createdAt: DateTime.utc(2026, 6, 9),
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('Rooms with different ids are unequal', () {
    final a = Room(
      roomId: '01J',
      name: '',
      members: _members('kaitlyn'),
      createdAt: DateTime.utc(2026, 6, 9),
    );
    final b = Room(
      roomId: '01K',
      name: '',
      members: _members('kaitlyn'),
      createdAt: DateTime.utc(2026, 6, 9),
    );
    expect(a, isNot(equals(b)));
  });
}
