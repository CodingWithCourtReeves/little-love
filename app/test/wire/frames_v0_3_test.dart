import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  test('RoomsFrame parses members array', () {
    final raw =
        jsonDecode('''
{
  "kind":"Rooms",
  "rooms":[
    {"room_id":"01J","name":"Garden",
     "members":[
       {"username":"court","ed25519_pub":"AAAA","x25519_pub":"BBBB"},
       {"username":"kaitlyn","ed25519_pub":"CCCC","x25519_pub":"DDDD"}
     ],
     "created_at":"2026-06-10T17:00:00Z"}
  ]
}''')
            as Map<String, Object?>;
    final f = RoomServerFrame.fromJson(raw) as RoomsFrame;
    expect(f.rooms.single.name, 'Garden');
    expect(f.rooms.single.members.length, 2);
    expect(f.rooms.single.members.last.username, 'kaitlyn');
  });

  test('RoomCreatedFrame parses pending_invite when present', () {
    final raw =
        jsonDecode('''
{"kind":"RoomCreated","room_id":"01J","name":"Travel",
 "members":[{"username":"court","ed25519_pub":"AAAA","x25519_pub":"BBBB"}],
 "pending_invite":{"code":"amber-fern-locket-tide","qr_png_base64":"","expires_at":"2026-06-10T19:00:00Z"}
}''')
            as Map<String, Object?>;
    final f = RoomServerFrame.fromJson(raw) as RoomCreatedFrame;
    expect(f.roomId, '01J');
    expect(f.pendingInvite, isNotNull);
    expect(f.pendingInvite!.code, 'amber-fern-locket-tide');
  });

  test('RoomCreatedFrame.pendingInvite is null when absent', () {
    final raw =
        jsonDecode('''
{"kind":"RoomCreated","room_id":"01J","name":"",
 "members":[{"username":"court","ed25519_pub":"AAAA","x25519_pub":"BBBB"}]
}''')
            as Map<String, Object?>;
    final f = RoomServerFrame.fromJson(raw) as RoomCreatedFrame;
    expect(f.pendingInvite, isNull);
  });

  test('InviteConsumedFrame parses members payload', () {
    final raw =
        jsonDecode('''
{"kind":"InviteConsumed","room_id":"01J","name":"",
 "members":[
   {"username":"court","ed25519_pub":"AAAA","x25519_pub":"BBBB"},
   {"username":"kaitlyn","ed25519_pub":"CCCC","x25519_pub":"DDDD"}
 ]
}''')
            as Map<String, Object?>;
    final f = RoomServerFrame.fromJson(raw) as InviteConsumedFrame;
    expect(f.roomId, '01J');
    expect(f.members.length, 2);
    expect(f.members.first.username, 'court');
  });

  test('RoomRenamedFrame + MemberLeftFrame parse', () {
    final r = RoomServerFrame.fromJson(
      jsonDecode('{"kind":"RoomRenamed","room_id":"01J","name":"x"}')
          as Map<String, Object?>,
    );
    expect(r, isA<RoomRenamedFrame>());
    expect((r as RoomRenamedFrame).name, 'x');

    final l = RoomServerFrame.fromJson(
      jsonDecode('{"kind":"MemberLeft","room_id":"01J","username":"kaitlyn"}')
          as Map<String, Object?>,
    );
    expect(l, isA<MemberLeftFrame>());
    expect((l as MemberLeftFrame).username, 'kaitlyn');
  });

  test('SendFrame serializes bodies map', () {
    final f = SendFrame(
      roomId: '01J',
      bodies: const {'AAAA': 'ct1', 'BBBB': 'ct2'},
      clientMsgId: 'msg-1',
    );
    final j = f.toJson();
    expect(j['kind'], 'Send');
    expect(j['room_id'], '01J');
    expect(j['bodies'], {'AAAA': 'ct1', 'BBBB': 'ct2'});
    expect(j['client_msg_id'], 'msg-1');
  });

  test('CreateRoomFrame / RenameRoomFrame / LeaveRoomFrame serialize', () {
    final c = const CreateRoomFrame(
      name: 'Garden',
      inviteHumanPartner: false,
    ).toJson();
    expect(c['kind'], 'CreateRoom');
    expect(c['name'], 'Garden');
    expect(c['invite_human_partner'], false);

    final r = const RenameRoomFrame(roomId: '01J', name: 'x').toJson();
    expect(r['kind'], 'RenameRoom');
    expect(r['room_id'], '01J');
    expect(r['name'], 'x');

    final l = const LeaveRoomFrame(roomId: '01J').toJson();
    expect(l['kind'], 'LeaveRoom');
    expect(l['room_id'], '01J');
  });

  test('MessageFrame parses read flag (defaults false)', () {
    final unread = RoomServerFrame.fromJson(
      jsonDecode(
            '{"kind":"Message","id":"01J","room_id":"01J","from":"court",'
            '"ts":"2026-06-10T17:00:00Z","body":"ct"}',
          )
          as Map<String, Object?>,
    );
    expect((unread as MessageFrame).read, false);

    final read = RoomServerFrame.fromJson(
      jsonDecode(
            '{"kind":"Message","id":"01J","room_id":"01J","from":"court",'
            '"ts":"2026-06-10T17:00:00Z","body":"ct","read":true}',
          )
          as Map<String, Object?>,
    );
    expect((read as MessageFrame).read, true);
  });

  test('ReadFrame parses room, ids, reader', () {
    final f = RoomServerFrame.fromJson(
      jsonDecode(
            '{"kind":"Read","room_id":"01J",'
            '"message_ids":["01JA","01JB"],"reader":"kaitlyn"}',
          )
          as Map<String, Object?>,
    );
    expect(f, isA<ReadFrame>());
    final r = f as ReadFrame;
    expect(r.roomId, '01J');
    expect(r.messageIds, ['01JA', '01JB']);
    expect(r.reader, 'kaitlyn');
  });

  test('MarkReadFrame serializes', () {
    final j = const MarkReadFrame(
      roomId: '01J',
      upToMessageId: '01JZ',
    ).toJson();
    expect(j['kind'], 'MarkRead');
    expect(j['room_id'], '01J');
    expect(j['up_to_message_id'], '01JZ');
  });
}
