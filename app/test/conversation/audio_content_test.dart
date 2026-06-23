import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_content.dart';

void main() {
  final descriptor = AttachmentDescriptor(
    blobKey: 'blob',
    contentKeyB64: 'ck',
    nonceB64: 'nc',
    mime: 'audio/mp4',
    filename: 'memo.m4a',
    size: 999,
    width: 0,
    height: 0,
    durationMs: 3000,
    thumbB64: '',
    waveform: List<int>.filled(64, 7),
  );

  test('AudioContent encodes then decodes back to AudioContent', () {
    final encoded = AudioContent(descriptor, caption: 'hi').encode();
    final decoded = MessageContent.decode(encoded);
    expect(decoded, isA<AudioContent>());
    final a = decoded as AudioContent;
    expect(a.caption, 'hi');
    expect(a.descriptor.mime, 'audio/mp4');
    expect(a.descriptor.durationMs, 3000);
    expect(a.descriptor.waveform, List<int>.filled(64, 7));
  });

  test('empty caption is omitted and decodes to null', () {
    final decoded =
        MessageContent.decode(AudioContent(descriptor).encode())
            as AudioContent;
    expect(decoded.caption, isNull);
  });
}
