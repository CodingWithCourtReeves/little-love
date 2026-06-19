import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/screens/auth/auth_gate.dart';

class _StubStore implements AccountLocalStore {
  _StubStore(this.value);
  LocalAccount? value;
  @override
  Future<LocalAccount?> load() async => value;
  @override
  Future<void> save(LocalAccount a) async {
    value = a;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

void main() {
  testWidgets('null account renders the choice screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountLocalStoreProvider.overrideWithValue(_StubStore(null)),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Sign in with a recovery phrase'), findsOneWidget);
  });

  testWidgets('populated account renders the inbox shell', (tester) async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountLocalStoreProvider.overrideWithValue(_StubStore(acc)),
          // Pretend the room list has synced so HomeScreen shows the empty
          // pairing state rather than the "still syncing" blank canvas.
          inboxSyncedProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(home: AuthGate()),
      ),
    );
    await tester.pumpAndSettle();
    // HomeScreen renders the empty-rooms pairing placeholder when no rooms are
    // registered.
    expect(find.textContaining('Invite your partner'), findsOneWidget);
  });
}
