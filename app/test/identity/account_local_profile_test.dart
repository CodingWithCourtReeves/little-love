import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';

void main() {
  LocalAccount base() => LocalAccount(
        username: 'alice',
        ed25519PubBase64: 'e',
        x25519PubBase64: 'x',
        createdAt: DateTime.utc(2026),
      );

  test('defaults are null and survive JSON', () {
    final a = base();
    expect(a.displayName, isNull);
    expect(a.avatarPath, isNull);
    final back = LocalAccount.fromJson(a.toJson());
    expect(back.displayName, isNull);
  });

  test('back-compat: legacy JSON without profile keys loads', () {
    final legacy = {
      'username': 'bob',
      'ed25519_pub': 'e',
      'x25519_pub': 'x',
      'created_at': DateTime.utc(2026).toIso8601String(),
    };
    final a = LocalAccount.fromJson(legacy);
    expect(a.username, 'bob');
    expect(a.displayName, isNull);
  });

  test('copyWith sets fields and they round-trip', () {
    final a = base().copyWith(displayName: 'Ali', avatarPath: '/tmp/a.jpg');
    final back = LocalAccount.fromJson(a.toJson());
    expect(back.displayName, 'Ali');
    expect(back.avatarPath, '/tmp/a.jpg');
  });
}
