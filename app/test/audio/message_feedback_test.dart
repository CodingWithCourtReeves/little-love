import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/audio/message_feedback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('little_love/message_sounds');
  late List<String> soundCalls;
  late List<String?> hapticCalls;

  setUp(() {
    soundCalls = [];
    hapticCalls = [];
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      soundCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        hapticCalls.add(call.arguments as String?);
      }
      return null;
    });
  });

  tearDown(() {
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('sent() plays the sent sound and no haptic', () async {
    MessageFeedback().sent();
    await Future<void>.delayed(Duration.zero);
    expect(soundCalls, ['playSent']);
    expect(hapticCalls, isEmpty);
  });

  test('received() plays the received sound and a light haptic', () async {
    MessageFeedback().received();
    await Future<void>.delayed(Duration.zero);
    expect(soundCalls, ['playReceived']);
    expect(hapticCalls, ['HapticFeedbackType.lightImpact']);
  });

  test('received() throttles a burst into a single cue', () async {
    var t = DateTime(2026, 6, 26, 12, 0, 0);
    final fb = MessageFeedback(now: () => t);

    fb.received(); // fires
    t = t.add(const Duration(milliseconds: 50));
    fb.received(); // inside 150ms window → suppressed
    t = t.add(const Duration(milliseconds: 200));
    fb.received(); // window elapsed → fires again

    await Future<void>.delayed(Duration.zero);
    expect(soundCalls, ['playReceived', 'playReceived']);
    expect(hapticCalls, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.lightImpact',
    ]);
  });
}
