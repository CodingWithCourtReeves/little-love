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

/// Wires the native token stream to the live socket: when a token arrives,
/// send a RegisterPush over the current connection. No-op while offline; the
/// next token delivery (or app resume) re-sends. The APNs environment is
/// resolved natively from the signing profile (see `AppDelegate.apnsEnvironment`)
/// and carried alongside the token, so the server routes to the right Apple
/// endpoint regardless of Debug/Release build config.
class PushRegistration {
  PushRegistration(this._ref, this._push, this._deviceIdStore);

  final Ref _ref;
  final PushService _push;
  final DeviceIdStore _deviceIdStore;
  String? _lastToken;
  String? _lastEnvironment;
  String? _lastVoipToken;
  String? _lastVoipEnvironment;

  void start() {
    _push.onToken((hexToken, environment) {
      _lastToken = hexToken;
      _lastEnvironment = environment;
      _sendRegister(hexToken, environment, 'alert');
    });
    _push.onVoipToken((hexToken, environment) {
      _lastVoipToken = hexToken;
      _lastVoipEnvironment = environment;
      _sendRegister(hexToken, environment, 'voip');
    });
  }

  Future<void> _sendRegister(
    String hexToken,
    String environment,
    String tokenKind,
  ) async {
    final conn = _ref.read(liveConnectionProvider).valueOrNull;
    if (conn == null) return;
    final deviceId = await stableDeviceId(_deviceIdStore);
    conn.send(
      RegisterPushFrame(
        deviceId: deviceId,
        apnsToken: hexToken,
        environment: environment,
        tokenKind: tokenKind,
      ).toJson(),
    );
  }

  /// Re-send the last known tokens (call on reconnect / app resume).
  Future<void> resend() async {
    final t = _lastToken;
    final env = _lastEnvironment;
    if (t != null && env != null) await _sendRegister(t, env, 'alert');
    final vt = _lastVoipToken;
    final venv = _lastVoipEnvironment;
    if (vt != null && venv != null) await _sendRegister(vt, venv, 'voip');
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
