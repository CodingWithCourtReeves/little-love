import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/pairing/pairing_transport.dart';
import 'package:littlelove/screens/pair/enter_code.dart';
import 'package:littlelove/wire/frames.dart';

class _StubTransport implements PairingTransport {
  @override
  Future<InviteCreatedFrame> createInvite() => throw UnimplementedError();

  @override
  Future<InviteConsumedFrame> consumeInvite({
    required String code,
    required Uint8List signature,
  }) async => const InviteConsumedFrame(
    roomId: '01JNEWROOM',
    name: '',
    members: [
      Member(
        username: 'court',
        ed25519PubBase64: 'AAAA',
        x25519PubBase64: 'BBBB',
        isBot: false,
      ),
      Member(
        username: 'kaitlyn',
        ed25519PubBase64: 'CCCC',
        x25519PubBase64: 'DDDD',
        isBot: false,
      ),
    ],
  );
}

Future<DerivedIdentity> _identity() => derivedIdentityFromSigningSeedForTest(
  Uint8List(32)..fillRange(0, 32, 0x01),
);

void main() {
  testWidgets(
    'preview → confirm → consume puts a Room in inbox state, shows v0.3 roster',
    (tester) async {
      final mockHttp = MockClient((req) async {
        expect(req.url.path, '/invites/abandon-abandon-abandon-ability/preview');
        return http.Response(
          jsonEncode({
            'room_id': '01JNEWROOM',
            'name': '',
            'members': [
              {
                'username': 'court',
                'ed25519_pub': 'AAAA',
                'x25519_pub': 'BBBB',
                'is_bot': false,
              },
              {
                'username': 'court-garden',
                'ed25519_pub': 'EEEE',
                'x25519_pub': 'FFFF',
                'is_bot': true,
                'owner_username': 'court',
              },
            ],
            'expires_at': '2026-06-09T18:00:00Z',
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final identity = await _identity();
      final container = ProviderContainer(
        overrides: [
          pairingTransportProvider.overrideWithValue(_StubTransport()),
          httpClientProvider.overrideWithValue(mockHttp),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: EnterCodeScreen(identity: identity, selfUsername: 'kaitlyn'),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const Key('enter-code-field')),
        'abandon-abandon-abandon-ability',
      );
      await tester.tap(find.byKey(const Key('preview-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Pair with @court'), findsOneWidget);
      expect(find.byKey(const Key('preview-roster-card')), findsOneWidget);
      expect(find.text('court'), findsOneWidget);
      expect(find.textContaining("court's court-garden"), findsOneWidget);
      expect(find.textContaining('You · kaitlyn'), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm-pair-button')));
      await tester.pumpAndSettle();

      final inbox = container.read(inboxStateProvider);
      expect(inbox.rooms.length, 1);
      expect(inbox.rooms.single.roomId, '01JNEWROOM');
      expect(
        inbox.rooms.single.members.map((m) => m.username).toList(),
        containsAll(<String>['court', 'kaitlyn']),
      );
    },
  );

  testWidgets('malformed code is rejected before any REST call', (
    tester,
  ) async {
    final identity = await _identity();
    final mockHttp = MockClient((_) async {
      fail('REST should not be hit for malformed codes');
    });
    final container = ProviderContainer(
      overrides: [
        pairingTransportProvider.overrideWithValue(_StubTransport()),
        httpClientProvider.overrideWithValue(mockHttp),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: EnterCodeScreen(identity: identity, selfUsername: 'kaitlyn'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('enter-code-field')),
      'this-is-not-real',
    );
    await tester.tap(find.byKey(const Key('preview-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Invalid invite code'), findsOneWidget);
  });
}
