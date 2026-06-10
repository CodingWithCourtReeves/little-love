import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:littlelove/wire/rest_client.dart';

void main() {
  group('RestClient.previewInvite', () {
    test('200 returns InvitePreviewResponse', () async {
      final mock = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.path, '/invites/amber-fern-locket-tide/preview');
        return http.Response(
          '{"inviter_username":"court","inviter_ed25519_pub":"AAAA",'
          '"inviter_x25519_pub":"BBBB","expires_at":"2026-06-09T18:00:00Z"}',
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final client = RestClient(
        baseUri: Uri.parse('http://localhost:7707'),
        httpClient: mock,
      );
      final r = await client.previewInvite('amber-fern-locket-tide');
      expect(r.inviterUsername, 'court');
      expect(r.inviterEd25519PubBase64, 'AAAA');
      expect(r.inviterX25519PubBase64, 'BBBB');
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
