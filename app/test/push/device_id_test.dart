import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/push/push_registration.dart';

class _MapStore implements DeviceIdStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

void main() {
  test('stableDeviceId persists across calls', () async {
    final store = _MapStore();
    final first = await stableDeviceId(store);
    final second = await stableDeviceId(store);
    expect(first, isNotEmpty);
    expect(first, second, reason: 'device id must be stable per install');
  });
}
