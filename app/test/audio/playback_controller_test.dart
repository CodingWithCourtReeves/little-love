import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/audio/playback_controller.dart';

class FakePlayer implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<void>.broadcast();
  bool playing = false;
  String? loadedPath;
  double speed = 1.0;
  Duration? lastSeek;

  // Real just_audio leaves `playing` latched true on completion (it parks at
  // the end), so the controller must explicitly pause — emit only the event.
  void complete() => _completed.add(null);

  @override
  Future<void> setFilePath(String path) async => loadedPath = path;
  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration to) async => lastSeek = to;
  @override
  Future<void> setSpeed(double s) async => speed = s;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<void> get onCompleted => _completed.stream;
  @override
  Future<void> dispose() async {}
}

AttachmentDescriptor _audio(String blob) => AttachmentDescriptor(
  blobKey: blob,
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: '$blob.m4a',
  size: 1,
  width: 0,
  height: 0,
  durationMs: 1000,
  thumbB64: '',
  waveform: List<int>.filled(64, 4),
);

void main() {
  test('toggling a new memo loads + plays and becomes active', () async {
    final fake = FakePlayer();
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d, conn) async => '/tmp/${d.blobKey}.m4a',
    );
    await c.toggle(_audio('a'), null);
    expect(fake.loadedPath, '/tmp/a.m4a');
    expect(fake.playing, isTrue);
    expect(c.activeBlobKey, 'a');
  });

  test('toggling the active memo again pauses it', () async {
    final fake = FakePlayer();
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d, conn) async => '/tmp/${d.blobKey}.m4a',
    );
    final a = _audio('a');
    await c.toggle(a, null);
    await c.toggle(a, null);
    expect(fake.playing, isFalse);
  });

  test('after a memo completes, toggling replays it from the start', () async {
    final fake = FakePlayer();
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d, conn) async => '/tmp/${d.blobKey}.m4a',
    );
    final a = _audio('a');
    await c.toggle(a, null);
    expect(fake.playing, isTrue);
    fake.complete();
    await Future<void>.delayed(Duration.zero);
    // Completion must actually pause the player (no auto-loop) and rewind.
    expect(fake.playing, isFalse);
    expect(c.isPlaying, isFalse);
    expect(fake.lastSeek, Duration.zero);
    // Tapping again replays (it's still the active memo, now paused at 0).
    await c.toggle(a, null);
    expect(fake.playing, isTrue);
  });

  test('a failed load is swallowed and leaves the memo replayable', () async {
    final fake = FakePlayer();
    var calls = 0;
    final c = VoicePlaybackController(
      backend: fake,
      resolvePath: (d, conn) async {
        calls++;
        if (calls == 1) throw Exception('download failed');
        return '/tmp/${d.blobKey}.m4a';
      },
    );
    final a = _audio('a');
    // First tap: resolve throws — must not propagate, and must not leave the
    // memo stuck "active" (so the button is live for a retry).
    await c.toggle(a, null);
    expect(c.isPlaying, isFalse);
    expect(c.activeBlobKey, isNull);
    // Second tap: resolve succeeds, plays.
    await c.toggle(a, null);
    expect(fake.playing, isTrue);
    expect(c.activeBlobKey, 'a');
  });

  test('cycleSpeed walks 1.0 -> 1.5 -> 2.0 -> 1.0', () {
    final c = VoicePlaybackController(
      backend: FakePlayer(),
      resolvePath: (d, conn) async => '',
    );
    expect(c.speed, 1.0);
    c.cycleSpeed();
    expect(c.speed, 1.5);
    c.cycleSpeed();
    expect(c.speed, 2.0);
    c.cycleSpeed();
    expect(c.speed, 1.0);
  });
}
