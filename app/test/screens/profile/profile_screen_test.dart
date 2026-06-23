import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/screens/profile/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows handle read-only and a sign-out action', (tester) async {
    final acc = LocalAccount(
      username: 'alice',
      ed25519PubBase64: 'e',
      x25519PubBase64: 'x',
      createdAt: DateTime.utc(2026),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith((ref) async => acc)],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    // The handle copy makes clear it's immutable.
    expect(find.textContaining("can't be changed"), findsOneWidget);
  });
}
