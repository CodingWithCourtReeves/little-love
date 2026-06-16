import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u, {bool bot = false, String? owner}) => Member(
  username: u,
  ed25519PubBase64: '',
  x25519PubBase64: '',
  isBot: bot,
  ownerUsername: owner,
);

Room r(List<Member> members, {String name = ''}) => Room(
  roomId: 'r',
  name: name,
  members: members,
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  group('§7.1 derived display names', () {
    test('couple-only → partner name', () {
      expect(r([m('court'), m('kaitlyn')]).displayName('court'), 'Kaitlyn');
    });

    test('solo + 1 bot → bot label', () {
      expect(
        r([
          m('court'),
          m('court-garden', bot: true, owner: 'court'),
        ]).displayName('court'),
        'Garden',
      );
    });

    test('solo + 2 bots → alpha-sorted bot labels', () {
      expect(
        r([
          m('court'),
          m('court-garden', bot: true, owner: 'court'),
          m('court-journal', bot: true, owner: 'court'),
        ]).displayName('court'),
        'Garden + Journal',
      );
    });

    test('couple + bot → partner then bot', () {
      expect(
        r([
          m('court'),
          m('kaitlyn'),
          m('court-garden', bot: true, owner: 'court'),
        ]).displayName('court'),
        'Kaitlyn + Garden',
      );
    });

    test('couple + 2 bots → partner then alpha-sorted bots', () {
      expect(
        r([
          m('court'),
          m('kaitlyn'),
          m('court-garden', bot: true, owner: 'court'),
          m('court-journal', bot: true, owner: 'court'),
        ]).displayName('court'),
        'Kaitlyn + Garden + Journal',
      );
    });
  });

  test('explicit name overrides derivation', () {
    expect(
      r([m('court'), m('kaitlyn')], name: 'Daily life').displayName('court'),
      'Daily life',
    );
  });

  group('shape classification', () {
    test('two humans, unnamed → partner', () {
      expect(r([m('court'), m('kaitlyn')]).shape('court'), RoomShape.partner);
    });

    test('one bot, unnamed → familiar', () {
      expect(
        r([
          m('court'),
          m('court-garden', bot: true, owner: 'court'),
        ]).shape('court'),
        RoomShape.familiar,
      );
    });

    test('partner plus bot → chat', () {
      expect(
        r([
          m('court'),
          m('kaitlyn'),
          m('court-garden', bot: true, owner: 'court'),
        ]).shape('court'),
        RoomShape.chat,
      );
    });

    test('named room with just partner → chat', () {
      expect(
        r([m('court'), m('kaitlyn')], name: 'travel').shape('court'),
        RoomShape.chat,
      );
    });

    test('multiple bots → chat', () {
      expect(
        r([
          m('court'),
          m('court-garden', bot: true, owner: 'court'),
          m('court-journal', bot: true, owner: 'court'),
        ]).shape('court'),
        RoomShape.chat,
      );
    });
  });

  group('lookup helpers', () {
    test('memberByPubkey finds by x25519', () {
      final r0 = Room(
        roomId: 'r',
        name: '',
        members: [
          Member(
            username: 'a',
            ed25519PubBase64: 'AAAA',
            x25519PubBase64: 'BBBB',
            isBot: false,
          ),
          Member(
            username: 'b',
            ed25519PubBase64: 'CCCC',
            x25519PubBase64: 'DDDD',
            isBot: false,
          ),
        ],
        createdAt: DateTime.utc(2026, 6, 10),
      );
      expect(r0.memberByPubkey('BBBB')!.username, 'a');
      expect(r0.memberByPubkey('DDDD')!.username, 'b');
      expect(r0.memberByPubkey('ZZZZ'), isNull);
    });

    test('memberByUsername finds by username', () {
      final r0 = r([m('a'), m('b')]);
      expect(r0.memberByUsername('a')!.username, 'a');
      expect(r0.memberByUsername('zzz'), isNull);
    });
  });
}
