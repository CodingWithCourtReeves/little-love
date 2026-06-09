import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('llove_test_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('write then read round-trips a LocalAccount', () async {
    final store = AccountLocalStore(homeDirectory: tmp);
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026, 6, 9, 17),
    );
    await store.save(acc);
    final round = await store.load();
    expect(round, isNotNull);
    expect(round!.username, 'court');
    expect(round.ed25519PubBase64, 'AAAA');
    expect(round.x25519PubBase64, 'BBBB');
    expect(round.createdAt, DateTime.utc(2026, 6, 9, 17));
  });

  test('load returns null when the file does not exist', () async {
    final store = AccountLocalStore(homeDirectory: tmp);
    expect(await store.load(), isNull);
  });

  test('delete removes the file', () async {
    final store = AccountLocalStore(homeDirectory: tmp);
    await store.save(LocalAccount(
      username: 'k',
      ed25519PubBase64: 'CCCC',
      x25519PubBase64: 'DDDD',
      createdAt: DateTime.utc(2026, 6, 9),
    ));
    await store.delete();
    expect(await store.load(), isNull);
  });
}
