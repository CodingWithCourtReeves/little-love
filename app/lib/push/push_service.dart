import 'package:flutter/services.dart';

/// Dart side of the native push bridge (`little_love/push`). Wraps permission
/// requests, the cold-launch room handoff, the host→Dart token/tap events, and
/// the App Group palette write.
class PushService {
  PushService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('little_love/push') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  void Function(String hexToken)? _onToken;
  void Function(String roomId)? _onTap;

  /// Ask the OS for notification permission. Returns whether it was granted.
  Future<bool> requestPermission() async {
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }

  /// Drain a room id captured from a notification tap that cold-launched the
  /// app. Returns null if there was none.
  Future<String?> takePendingLaunchRoom() =>
      _channel.invokeMethod<String?>('takePendingLaunchRoom');

  /// Write the selected palette key into the shared App Group so the
  /// Notification Service Extension renders the matching artwork. Today always
  /// 'twilight'; the future palette switcher calls this with the new key.
  Future<void> setPalette(String key) =>
      _channel.invokeMethod<void>('setPalette', key);

  /// Register a callback for APNs token delivery / refresh.
  void onToken(void Function(String hexToken) cb) => _onToken = cb;

  /// Register a callback for a live notification tap (app already running).
  void onTap(void Function(String roomId) cb) => _onTap = cb;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final t = call.arguments as String?;
        if (t != null) _onToken?.call(t);
        return null;
      case 'onTap':
        final r = call.arguments as String?;
        if (r != null) _onTap?.call(r);
        return null;
      default:
        return null;
    }
  }
}
