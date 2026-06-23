import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/audio/playback_controller.dart';
import 'package:littlelove/conversation/audio_bubble.dart';

AttachmentDescriptor _audio() => AttachmentDescriptor(
  blobKey: 'a',
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: 'a.m4a',
  size: 1,
  width: 0,
  height: 0,
  durationMs: 65000,
  thumbB64: '',
  waveform: List<int>.filled(64, 10),
);

// Minimal no-op player so constructing the controller doesn't touch hardware.
class _NoopPlayer implements PlayerBackend {
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #playingStream) return const Stream<bool>.empty();
    if (i.memberName == #positionStream) return const Stream<Duration>.empty();
    if (i.memberName == #durationStream) return const Stream<Duration?>.empty();
    if (i.memberName == #onCompleted) return const Stream<void>.empty();
    return Future<void>.value();
  }
}

void main() {
  testWidgets('renders play button, duration, and a waveform', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioBubble(
            descriptor: _audio(),
            isMe: true,
            controller: VoicePlaybackController(
              backend: _NoopPlayer(),
              resolvePath: (d, conn) async => '',
            ),
            conn: null,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('audio-play')), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.byKey(const Key('audio-waveform')), findsOneWidget);
  });
}
