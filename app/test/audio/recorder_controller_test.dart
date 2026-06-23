import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/audio/recorder_controller.dart';

class FakeBackend implements RecorderBackend {
  FakeBackend({this.permission = true});
  final bool permission;
  final _amp = StreamController<double>.broadcast();
  bool started = false;
  bool stopped = false;
  String? lastPath;

  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<void> start(String path) async {
    started = true;
    lastPath = path;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return lastPath;
  }

  @override
  Stream<double> amplitudeStream() => _amp.stream;

  void emit(double db) => _amp.add(db);
}

void main() {
  test('start moves idle -> recording and begins capture', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(
      backend: be,
      tempPathFactory: () async => '/tmp/voice_test.m4a',
    );
    expect(c.state, RecorderState.idle);
    expect(await c.start(), isTrue);
    expect(c.state, RecorderState.recording);
    expect(be.started, isTrue);
  });

  test(
    'start returns false and stays idle when permission is denied',
    () async {
      final be = FakeBackend(permission: false);
      final c = VoiceRecorderController(
        backend: be,
        tempPathFactory: () async => '/tmp/voice_test.m4a',
      );
      expect(await c.start(), isFalse);
      expect(c.state, RecorderState.idle);
      expect(be.started, isFalse);
    },
  );

  test('lock moves recording -> locked', () async {
    final c = VoiceRecorderController(
      backend: FakeBackend(),
      tempPathFactory: () async => '/tmp/voice_test.m4a',
    );
    await c.start();
    c.lock();
    expect(c.state, RecorderState.locked);
  });

  test('stop returns a recording with a 64-peak waveform', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(
      backend: be,
      tempPathFactory: () async => '/tmp/voice_test.m4a',
    );
    await c.start();
    be.emit(-5.0);
    be.emit(-50.0);
    await Future<void>.delayed(Duration.zero);
    final rec = await c.stop();
    expect(c.state, RecorderState.stopped);
    expect(rec, isNotNull);
    expect(rec!.waveform.length, 64);
    expect(be.stopped, isTrue);
  });

  test('cancel deletes capture and moves to cancelled', () async {
    final be = FakeBackend();
    final c = VoiceRecorderController(
      backend: be,
      tempPathFactory: () async => '/tmp/voice_test.m4a',
    );
    await c.start();
    await c.cancel();
    expect(c.state, RecorderState.cancelled);
    expect(be.stopped, isTrue);
  });
}
