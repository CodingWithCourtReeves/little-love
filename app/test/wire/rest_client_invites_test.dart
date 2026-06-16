import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:littlelove/wire/rest_client.dart';

void main() {
  group('RestClient.previewInvite (v0.3)', () {
    test('200 returns roster InvitePreviewResponse', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/invites/amber-fern-locket-tide/preview');
        return http.Response(
          '{"room_id":"01JNROOM",'
          '"name":"",'
          '"members":['
          '{"username":"court","ed25519_pub":"AAAA","x25519_pub":"BBBB","is_bot":false},'
          '{"username":"court-garden","ed25519_pub":"EEEE","x25519_pub":"FFFF",'
          '"is_bot":true,"owner_username":"court"}'
          '],'
          '"expires_at":"2026-06-09T18:00:00Z"}',
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final client = RestClient(
        baseUri: Uri.parse('http://localhost:7707'),
        httpClient: mock,
      );
      final r = await client.previewInvite('amber-fern-locket-tide');
      expect(r.roomId, '01JNROOM');
      expect(r.name, '');
      expect(r.members.map((m) => m.username).toList(), [
        'court',
        'court-garden',
      ]);
      expect(r.members[0].isBot, isFalse);
      expect(r.members[1].isBot, isTrue);
      expect(r.members[1].ownerUsername, 'court');
      expect(r.expiresAt.toUtc(), DateTime.utc(2026, 6, 9, 18, 0, 0));
    });

    test('404 throws InviteNotFoundException', () async {
      final mock = MockClient((_) async => http.Response('nope', 404));
      final client = RestClient(
        baseUri: Uri.parse('http://localhost:7707'),
        httpClient: mock,
      );
      expect(
        () => client.previewInvite('x-y-z-w'),
        throwsA(isA<InviteNotFoundException>()),
      );
    });

    test('410 throws InviteGoneException', () async {
      final mock = MockClient((_) async => http.Response('gone', 410));
      final client = RestClient(
        baseUri: Uri.parse('http://localhost:7707'),
        httpClient: mock,
      );
      expect(
        () => client.previewInvite('x-y-z-w'),
        throwsA(isA<InviteGoneException>()),
      );
    });
  });
}
