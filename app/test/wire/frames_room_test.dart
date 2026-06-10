import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  group('Room server frames (spec §8.2)', () {
    test('parses a Rooms frame', () {
      final frame = RoomServerFrame.fromJson(
        jsonDecode('''
        {"kind":"Rooms","rooms":[
          {"room_id":"01J","peer_username":"kaitlyn","peer_ed25519_pub":"AAAA",
           "peer_x25519_pub":"BBBB","created_at":"2026-06-09T17:00:00Z"}
        ]}
      ''')
            as Map<String, Object?>,
      );
      expect(frame, isA<RoomsFrame>());
      final r = (frame as RoomsFrame).rooms.single;
      expect(r.roomId, '01J');
      expect(r.peerUsername, 'kaitlyn');
      expect(r.peerEd25519PubBase64, 'AAAA');
      expect(r.peerX25519PubBase64, 'BBBB');
    });

    test('parses InviteCreated', () {
      final f = RoomServerFrame.fromJson(
        jsonDecode(
              '{"kind":"InviteCreated","code":"amber-fern-locket-tide",'
              '"qr_png_base64":"AAAA","expires_at":"2026-06-09T18:00:00Z"}',
            )
            as Map<String, Object?>,
      );
      expect(f, isA<InviteCreatedFrame>());
      final c = f as InviteCreatedFrame;
      expect(c.code, 'amber-fern-locket-tide');
      expect(c.qrPngBase64, 'AAAA');
      expect(c.expiresAt.toUtc(), DateTime.utc(2026, 6, 9, 18, 0, 0));
    });

    test('parses InviteConsumed', () {
      final f = RoomServerFrame.fromJson(
        jsonDecode(
              '{"kind":"InviteConsumed","room_id":"01J","peer_username":"court",'
              '"peer_ed25519_pub":"AAAA","peer_x25519_pub":"BBBB"}',
            )
            as Map<String, Object?>,
      );
      expect(f, isA<InviteConsumedFrame>());
      expect((f as InviteConsumedFrame).roomId, '01J');
    });

    test('parses RoomCreated', () {
      final f = RoomServerFrame.fromJson(
        jsonDecode(
              '{"kind":"RoomCreated","room_id":"01J","peer_username":"kaitlyn",'
              '"peer_ed25519_pub":"AAAA","peer_x25519_pub":"BBBB"}',
            )
            as Map<String, Object?>,
      );
      expect(f, isA<RoomCreatedFrame>());
    });

    test('parses Message with replayed default false', () {
      final f = RoomServerFrame.fromJson(
        jsonDecode(
              '{"kind":"Message","id":"m1","room_id":"01J","from":"court",'
              '"ts":"2026-06-09T17:00:00Z","body":"ciphertext"}',
            )
            as Map<String, Object?>,
      );
      expect(f, isA<MessageFrame>());
      final m = f as MessageFrame;
      expect(m.id, 'm1');
      expect(m.body, 'ciphertext');
      expect(m.replayed, isFalse);
    });
  });

  group('Room client frames', () {
    test('CreateInvite serialises', () {
      expect(const CreateInviteFrame().toJson(), {'kind': 'CreateInvite'});
    });

    test('ConsumeInvite serialises with code + signature', () {
      const f = ConsumeInviteFrame(
        code: 'amber-fern-locket-tide',
        signatureBase64: 'sig',
      );
      expect(f.toJson(), {
        'kind': 'ConsumeInvite',
        'code': 'amber-fern-locket-tide',
        'signature_over_token': 'sig',
      });
    });

    test('Subscribe serialises with nullable since_message_id', () {
      expect(
        const SubscribeFrame(roomId: '01J', sinceMessageId: null).toJson(),
        {'kind': 'Subscribe', 'room_id': '01J', 'since_message_id': null},
      );
      expect(
        const SubscribeFrame(roomId: '01J', sinceMessageId: 'm5').toJson(),
        {'kind': 'Subscribe', 'room_id': '01J', 'since_message_id': 'm5'},
      );
    });

    test('Send serialises', () {
      const f = SendFrame(
        roomId: '01J',
        body: 'ciphertext',
        clientMsgId: 'uuid-1',
      );
      expect(f.toJson(), {
        'kind': 'Send',
        'room_id': '01J',
        'body': 'ciphertext',
        'client_msg_id': 'uuid-1',
      });
    });
  });
}
