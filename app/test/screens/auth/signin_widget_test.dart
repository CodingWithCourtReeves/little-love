import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/bip39.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/screens/auth/signin.dart';
import 'package:littlelove/wire/rest_client.dart';

void main() {
  testWidgets('successful sign-in fires onRestored with account + seed', (
    tester,
  ) async {
    final seedBytes = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final phrase = seedToPhrase(seedBytes);
    final id = await deriveIdentity(seedBytes);
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'username': 'court',
          'ed25519_pub': base64.encode(id.ed25519PublicKey),
          'x25519_pub': base64.encode(id.x25519PublicKey),
          'created_at': '2026-06-09T00:00:00Z',
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    LocalAccount? restored;
    List<int>? seedOut;
    await tester.pumpWidget(
      MaterialApp(
        home: SigninScreen(
          rest: RestClient(
            baseUri: Uri.parse('http://example'),
            httpClient: client,
          ),
          onRestored: (a, s) {
            restored = a;
            seedOut = s;
          },
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('username')), 'court');
    await tester.enterText(find.byKey(const ValueKey('phrase')), phrase);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(restored, isNotNull);
    expect(restored!.username, 'court');
    expect(seedOut, isNotNull);
    expect(seedOut!.length, 16);
  });

  testWidgets('mismatched pubkey shows error', (tester) async {
    final seedBytes = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final phrase = seedToPhrase(seedBytes);
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'username': 'court',
          'ed25519_pub': base64.encode(List<int>.filled(32, 0)),
          'x25519_pub': base64.encode(List<int>.filled(32, 0)),
          'created_at': '2026-06-09T00:00:00Z',
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SigninScreen(
          rest: RestClient(
            baseUri: Uri.parse('http://example'),
            httpClient: client,
          ),
          onRestored: (_, _) {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('username')), 'court');
    await tester.enterText(find.byKey(const ValueKey('phrase')), phrase);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('different account'), findsOneWidget);
  });

  testWidgets('unknown username shows not-found error', (tester) async {
    final seedBytes = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final phrase = seedToPhrase(seedBytes);
    final client = MockClient((_) async => http.Response('', 404));
    await tester.pumpWidget(
      MaterialApp(
        home: SigninScreen(
          rest: RestClient(
            baseUri: Uri.parse('http://example'),
            httpClient: client,
          ),
          onRestored: (_, _) {},
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('username')), 'nope');
    await tester.enterText(find.byKey(const ValueKey('phrase')), phrase);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('no account named'), findsOneWidget);
  });
}
