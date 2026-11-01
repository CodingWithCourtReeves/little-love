/// The device check behind the app lock: Face ID, falling back to the iPhone
/// passcode. A seam so tests don't call the platform.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

abstract class DeviceAuth {
  /// Whether this iPhone can check who's holding it (Face ID or a passcode is
  /// set up).
  Future<bool> isAvailable();

  /// Show the Face ID sheet (with the passcode as the fallback). True when the
  /// user got through; false when they cancelled or failed.
  Future<bool> authenticate();
}

class LocalDeviceAuth implements DeviceAuth {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() => _auth.isDeviceSupported();

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Little Love to see your chats.',
        // Face ID first, the iPhone passcode as the fallback.
        biometricOnly: false,
      );
    } on LocalAuthException catch (e) {
      // A cancel, a lockout after too many tries, or the system cutting the
      // sheet off: the app stays locked and the Unlock button retries.
      debugPrint('lock: not unlocked (${e.code.name})');
      return false;
    } on PlatformException catch (e) {
      debugPrint('lock: not unlocked (${e.code})');
      return false;
    }
  }
}

final deviceAuthProvider = Provider<DeviceAuth>((ref) => LocalDeviceAuth());
