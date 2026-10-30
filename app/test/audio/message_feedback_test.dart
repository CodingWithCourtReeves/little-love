import 'package:fake_async/fake_async.dart';
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

  test('heartbeat() plays a medium beat, then a light one 130ms later', () {
    fakeAsync((async) {
      MessageFeedback().heartbeat();
      async.flushMicrotasks();
      expect(hapticCalls, ['HapticFeedbackType.mediumImpact']);
      async.elapse(const Duration(milliseconds: 129));
      expect(hapticCalls, ['HapticFeedbackType.mediumImpact']);
      async.elapse(const Duration(milliseconds: 1));
      expect(hapticCalls, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
      expect(soundCalls, isEmpty);
    });
  });

  test('received(loveTap: true) chimes and plays the heartbeat', () {
    fakeAsync((async) {
      MessageFeedback().received(loveTap: true);
      async.elapse(MessageFeedback.heartbeatGap);
      expect(soundCalls, ['playReceived']);
      expect(hapticCalls, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
    });
  });

  test('reactionReceived() taps lightly on the badge pop, without a chime', () {
    fakeAsync((async) {
      MessageFeedback().reactionReceived();
      async.elapse(const Duration(milliseconds: 149));
      expect(hapticCalls, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(hapticCalls, ['HapticFeedbackType.lightImpact']);
      expect(soundCalls, isEmpty);
    });
  });

  test('reactionReceived() throttles a burst into a single tap', () {
    fakeAsync((async) {
      var t = DateTime(2026, 10, 30, 12, 0, 0);
      final fb = MessageFeedback(now: () => t);
      fb.reactionReceived(); // fires
      t = t.add(const Duration(milliseconds: 50));
      fb.reactionReceived(); // inside 150ms window → suppressed
      async.elapse(const Duration(seconds: 1));
      expect(hapticCalls, ['HapticFeedbackType.lightImpact']);
    });
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
