import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/keystore.dart';

void main() {
  group('InMemoryKeystore', () {
    test('write → read → delete round-trip', () async {
      final ks = InMemoryKeystore();
      await ks.write('llove.master.court', 'secret');
      expect(await ks.read('llove.master.court'), 'secret');
      await ks.delete('llove.master.court');
      expect(await ks.read('llove.master.court'), isNull);
    });

    test('read of unknown key returns null', () async {
      final ks = InMemoryKeystore();
      expect(await ks.read('absent'), isNull);
    });
  });

  group('SecureKeystore (channel-mocked)', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final store = <String, String>{};

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, Object?>() ?? {};
            switch (call.method) {
              case 'write':
                store[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return store[args['key'] as String];
              case 'delete':
                store.remove(args['key'] as String);
                return null;
              case 'containsKey':
                return store.containsKey(args['key'] as String);
              default:
                return null;
            }
          });
    });

    tearDown(() {
      store.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('write then read round-trips through the channel', () async {
      final ks = SecureKeystore();
      await ks.write('llove.master.court', 'abc');
      expect(await ks.read('llove.master.court'), 'abc');
    });

    test('delete removes the value', () async {
      final ks = SecureKeystore();
      await ks.write('k', 'v');
      await ks.delete('k');
      expect(await ks.read('k'), isNull);
    });
  });
}
