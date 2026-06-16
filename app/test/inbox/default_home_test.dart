import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u) => Member(
  username: u,
  ed25519PubBase64: '',
  x25519PubBase64: '',
);

Room room(String id, List<Member> members, {String name = '', int day = 14}) =>
    Room(
      roomId: id,
      name: name,
      members: members,
      createdAt: DateTime.utc(2026, 6, day),
    );

void main() {
  test('defaultHomeRoomId prefers the partner room', () {
    final partner = room('p', [m('court'), m('kaitlyn')]);
    final channel = room('c', [m('court'), m('kaitlyn')], name: 'logistics');
    expect(defaultHomeRoomId([channel, partner], 'court'), 'p');
  });

  test('defaultHomeRoomId falls back to most recent when no partner room', () {
    final older = room('a', [m('court'), m('kaitlyn')], name: 'x', day: 10);
    final newer = room('b', [m('court'), m('kaitlyn')], name: 'y', day: 14);
    expect(defaultHomeRoomId([older, newer], 'court'), 'b');
  });

  test('defaultHomeRoomId returns null for empty', () {
    expect(defaultHomeRoomId(const [], 'court'), isNull);
  });
}
