import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/push/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('little_love/push');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('requestPermission returns the native grant result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestPermission') return true;
      return null;
    });
    final svc = PushService();
    expect(await svc.requestPermission(), isTrue);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('takePendingLaunchRoom forwards the native value', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'takePendingLaunchRoom') return '01ROOM';
      return null;
    });
    final svc = PushService();
    expect(await svc.takePendingLaunchRoom(), '01ROOM');
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('onToken fires when native invokes onToken', () async {
    final svc = PushService();
    String? got;
    svc.onToken((t) => got = t);
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('onToken', 'deadbeef')),
      (_) {},
    );
    expect(got, 'deadbeef');
  });

  test('onTap fires when native invokes onTap', () async {
    final svc = PushService();
    String? got;
    svc.onTap((r) => got = r);
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('onTap', '01ROOM')),
      (_) {},
    );
    expect(got, '01ROOM');
  });

  test('setPalette sends the key to native', () async {
    Object? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setPalette') sent = call.arguments;
      return null;
    });
    await PushService().setPalette('twilight');
    expect(sent, 'twilight');
    messenger.setMockMethodCallHandler(channel, null);
  });
}
