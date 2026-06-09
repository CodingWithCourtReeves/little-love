import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/keystore.dart';
import 'package:littlelove/identity/providers.dart';

class _FakeStore implements AccountLocalStore {
  _FakeStore({required this.value});
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
  test('accountProvider returns null when no LocalAccount is saved', () async {
    final container = ProviderContainer(overrides: [
      accountLocalStoreProvider.overrideWithValue(_FakeStore(value: null)),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(accountProvider.future), isNull);
  });

  test('accountProvider returns the saved LocalAccount', () async {
    final acc = LocalAccount(
      username: 'court',
      ed25519PubBase64: 'AAAA',
      x25519PubBase64: 'BBBB',
      createdAt: DateTime.utc(2026),
    );
    final container = ProviderContainer(overrides: [
      accountLocalStoreProvider.overrideWithValue(_FakeStore(value: acc)),
    ]);
    addTearDown(container.dispose);
    final got = await container.read(accountProvider.future);
    expect(got, isNotNull);
    expect(got!.username, 'court');
  });

  test('serverEndpointProvider builds REST and WSS URIs', () {
    final container = ProviderContainer(overrides: [
      serverBaseProvider.overrideWithValue(Uri.parse('http://127.0.0.1:7707')),
    ]);
    addTearDown(container.dispose);
    final ep = container.read(serverEndpointProvider);
    expect(ep.httpBase, Uri.parse('http://127.0.0.1:7707'));
    expect(ep.wsConnect.toString(), 'ws://127.0.0.1:7707/connect');
  });

  test('serverEndpointProvider promotes https to wss', () {
    final container = ProviderContainer(overrides: [
      serverBaseProvider.overrideWithValue(Uri.parse('https://prod.example')),
    ]);
    addTearDown(container.dispose);
    final ep = container.read(serverEndpointProvider);
    expect(ep.wsConnect.toString(), 'wss://prod.example/connect');
  });

  test('keystoreProvider can be overridden with InMemoryKeystore', () async {
    final container = ProviderContainer(overrides: [
      keystoreProvider.overrideWithValue(InMemoryKeystore()),
    ]);
    addTearDown(container.dispose);
    final ks = container.read(keystoreProvider);
    await ks.write('k', 'v');
    expect(await ks.read('k'), 'v');
  });
}
