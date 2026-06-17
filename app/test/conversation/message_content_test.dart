import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_content.dart';

void main() {
  test('text encodes to a versioned envelope and decodes back', () {
    final enc = const TextContent('hello').encode();
    final back = MessageContent.decode(enc);
    expect(back, isA<TextContent>());
    expect((back as TextContent).text, 'hello');
  });

  test('file envelope round-trips', () {
    const d = AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: 'a',
      nonceB64: 'b',
      mime: 'image/jpeg',
      filename: 'IMG.jpg',
      size: 1,
      width: 1,
      height: 1,
      durationMs: null,
      thumbB64: 't',
    );
    final back = MessageContent.decode(const FileContent(d).encode());
    expect(back, isA<FileContent>());
    expect((back as FileContent).descriptor.blobKey, 'k');
    expect(back.caption, isNull);
  });

  test('file envelope carries a caption through encode/decode', () {
    const d = AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: 'a',
      nonceB64: 'b',
      mime: 'image/jpeg',
      filename: 'IMG.jpg',
      size: 1,
      width: 1,
      height: 1,
      durationMs: null,
      thumbB64: 't',
    );
    final back = MessageContent.decode(
      const FileContent(d, caption: 'look at this').encode(),
    );
    expect(back, isA<FileContent>());
    expect((back as FileContent).caption, 'look at this');
  });

  test('empty caption is omitted from the envelope (decodes as null)', () {
    const d = AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: 'a',
      nonceB64: 'b',
      mime: 'image/jpeg',
      filename: 'IMG.jpg',
      size: 1,
      width: 1,
      height: 1,
      durationMs: null,
      thumbB64: 't',
    );
    final enc = const FileContent(d, caption: '').encode();
    expect(enc.contains('caption'), isFalse);
    final back = MessageContent.decode(enc);
    expect((back as FileContent).caption, isNull);
  });

  test('reaction envelope round-trips (target + emoji)', () {
    final enc = const ReactionContent(targetId: 'msg-1', emoji: '❤️').encode();
    final back = MessageContent.decode(enc);
    expect(back, isA<ReactionContent>());
    expect((back as ReactionContent).targetId, 'msg-1');
    expect(back.emoji, '❤️');
  });

  test('reaction with empty emoji (toggle-off) round-trips', () {
    final enc = const ReactionContent(targetId: 'msg-1', emoji: '').encode();
    final back = MessageContent.decode(enc) as ReactionContent;
    expect(back.targetId, 'msg-1');
    expect(back.emoji, isEmpty);
  });

  test('legacy bare string decodes as text (back-compat)', () {
    final back = MessageContent.decode('just a plain old message');
    expect(back, isA<TextContent>());
    expect((back as TextContent).text, 'just a plain old message');
  });
}
