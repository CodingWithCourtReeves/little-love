import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:littlelove/wire/rest_client.dart';

void main() {
  group('postAccount', () {
    test('POSTs the request body and parses 201', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req as http.Request;
        return http.Response(
          jsonEncode({
            'username': 'court',
            'created_at': '2026-06-09T19:32:00Z',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final rest = RestClient(
        baseUri: Uri.parse('http://example/'),
        httpClient: client,
      );
      final reply = await rest.postAccount(
        username: 'court',
        ed25519PubBase64: 'AAAA',
        x25519PubBase64: 'BBBB',
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/accounts');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['username'], 'court');
      expect(body['ed25519_pub'], 'AAAA');
      expect(body['x25519_pub'], 'BBBB');
      expect(reply.username, 'court');
    });

    test('throws UsernameTaken on 409', () async {
      final client = MockClient((_) async => http.Response('', 409));
      final rest = RestClient(
        baseUri: Uri.parse('http://example/'),
        httpClient: client,
      );
      expect(
        () => rest.postAccount(
          username: 'court',
          ed25519PubBase64: 'AAAA',
          x25519PubBase64: 'BBBB',
        ),
        throwsA(isA<UsernameTakenException>()),
      );
    });
  });

  group('getAccountByUsername', () {
    test('parses a 200 response', () async {
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'username': 'court',
            'ed25519_pub': 'AAAA',
            'x25519_pub': 'BBBB',
            'created_at': '2026-06-09T19:32:00Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final rest = RestClient(
        baseUri: Uri.parse('http://example/'),
        httpClient: client,
      );
      final acc = await rest.getAccountByUsername('court');
      expect(acc, isNotNull);
      expect(acc!.username, 'court');
      expect(acc.ed25519PubBase64, 'AAAA');
    });

    test('returns null on 404', () async {
      final client = MockClient((_) async => http.Response('', 404));
      final rest = RestClient(
        baseUri: Uri.parse('http://example/'),
        httpClient: client,
      );
      expect(await rest.getAccountByUsername('nope'), isNull);
    });
  });
}
