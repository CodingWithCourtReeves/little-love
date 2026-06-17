import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'push_service.dart';

/// Minimal key/value seam so the device-id logic is testable without the
/// platform keychain.
abstract class DeviceIdStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class SecureDeviceIdStore implements DeviceIdStore {
  SecureDeviceIdStore(this._storage);
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

const _deviceIdKey = 'push_device_id';

/// A UUID minted once per install and reused thereafter. Identifies this
/// device's token row server-side so re-registration upserts in place.
Future<String> stableDeviceId(DeviceIdStore store) async {
  final existing = await store.read(_deviceIdKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final fresh = const Uuid().v4();
  await store.write(_deviceIdKey, fresh);
  return fresh;
}

/// Sandbox for debug/profile builds, production for release. APNs tokens are
/// environment-specific, so we tell the server which to send through.
String currentApnsEnvironment() {
  // Release (no asserts) → production; debug/profile → sandbox.
  var inDebug = false;
  assert(() {
    inDebug = true;
    return true;
  }());
  return inDebug ? 'sandbox' : 'production';
}

/// Wires the native token stream to the live socket: when a token arrives,
/// send a RegisterPush over the current connection. No-op while offline; the
/// next token delivery (or app resume) re-sends.
class PushRegistration {
  PushRegistration(this._ref, this._push, this._deviceIdStore);

  final Ref _ref;
  final PushService _push;
  final DeviceIdStore _deviceIdStore;
  String? _lastToken;

  void start() {
    _push.onToken((hexToken) {
      _lastToken = hexToken;
      _sendRegister(hexToken);
    });
  }

  Future<void> _sendRegister(String hexToken) async {
    final conn = _ref.read(liveConnectionProvider).valueOrNull;
    if (conn == null) return;
    final deviceId = await stableDeviceId(_deviceIdStore);
    conn.send(
      RegisterPushFrame(
        deviceId: deviceId,
        apnsToken: hexToken,
        environment: currentApnsEnvironment(),
      ).toJson(),
    );
  }

  /// Re-send the last known token (call on reconnect / app resume).
  Future<void> resend() async {
    final t = _lastToken;
    if (t != null) await _sendRegister(t);
  }

  Future<void> unregister() async {
    final conn = _ref.read(liveConnectionProvider).valueOrNull;
    if (conn == null) return;
    final deviceId = await stableDeviceId(_deviceIdStore);
    conn.send(UnregisterPushFrame(deviceId: deviceId).toJson());
  }
}

final pushServiceProvider = Provider<PushService>((_) => PushService());

final pushRegistrationProvider = Provider<PushRegistration>((ref) {
  final reg = PushRegistration(
    ref,
    ref.watch(pushServiceProvider),
    SecureDeviceIdStore(const FlutterSecureStorage()),
  );
  reg.start();
  return reg;
});
