import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/link_preview.dart';
import 'package:littlelove/conversation/message_content.dart';
import 'package:littlelove/conversation/reply_ref.dart';

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

  test('text envelope carries a link preview through encode/decode', () {
    const preview = LinkPreview(
      url: 'https://example.com/a',
      title: 'A Title',
      description: 'A description',
      siteName: 'Example',
      imageB64: 'QUJD',
      imageWidth: 640,
      imageHeight: 360,
    );
    final enc = const TextContent(
      'look https://example.com/a',
      preview: preview,
    ).encode();
    final back = MessageContent.decode(enc) as TextContent;
    expect(back.text, 'look https://example.com/a');
    expect(back.preview, isNotNull);
    expect(back.preview!.title, 'A Title');
    expect(back.preview!.siteName, 'Example');
    expect(back.preview!.imageB64, 'QUJD');
    expect(back.preview!.imageWidth, 640);
    expect(back.preview!.imageHeight, 360);
  });

  test('plain text decodes with a null preview', () {
    final back = MessageContent.decode(const TextContent('hi').encode());
    expect((back as TextContent).preview, isNull);
  });

  test('delete envelope round-trips (target id)', () {
    final enc = const DeleteContent(targetId: 'msg-7').encode();
    final back = MessageContent.decode(enc);
    expect(back, isA<DeleteContent>());
    expect((back as DeleteContent).targetId, 'msg-7');
  });

  test('legacy bare string decodes as text (back-compat)', () {
    final back = MessageContent.decode('just a plain old message');
    expect(back, isA<TextContent>());
    expect((back as TextContent).text, 'just a plain old message');
  });

  test('edit envelope round-trips (target + new text)', () {
    final enc = const EditContent(
      targetId: 'msg-9',
      text: 'fixed text',
    ).encode();
    final back = MessageContent.decode(enc);
    expect(back, isA<EditContent>());
    expect((back as EditContent).targetId, 'msg-9');
    expect(back.text, 'fixed text');
    expect(back.preview, isNull);
  });

  test('edit envelope carries a link preview through encode/decode', () {
    const preview = LinkPreview(
      url: 'https://example.com/a',
      title: 'A Title',
      description: 'A description',
      siteName: 'Example',
      imageB64: 'QUJD',
      imageWidth: 640,
      imageHeight: 360,
    );
    final enc = const EditContent(
      targetId: 'msg-9',
      text: 'now with https://example.com/a',
      preview: preview,
    ).encode();
    final back = MessageContent.decode(enc) as EditContent;
    expect(back.text, 'now with https://example.com/a');
    expect(back.preview, isNotNull);
    expect(back.preview!.title, 'A Title');
    expect(back.preview!.siteName, 'Example');
  });

  const sampleDesc = AttachmentDescriptor(
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

  test('TextContent round-trips a replyTo with an excerpt', () {
    final enc = const TextContent(
      'ok',
      replyTo: ReplyRef(
        id: 'm1',
        author: 'court',
        kind: 'text',
        text: 'original',
      ),
    ).encode();
    final back = MessageContent.decode(enc) as TextContent;
    expect(back.replyTo, isNotNull);
    expect(back.replyTo!.id, 'm1');
    expect(back.replyTo!.author, 'court');
    expect(back.replyTo!.kind, 'text');
    expect(back.replyTo!.text, 'original');
  });

  test('FileContent round-trips a replyTo without an excerpt', () {
    final enc = const FileContent(
      sampleDesc,
      caption: 'hi',
      replyTo: ReplyRef(id: 'm2', author: 'kaitlyn', kind: 'photo'),
    ).encode();
    final back = MessageContent.decode(enc) as FileContent;
    expect(back.replyTo!.kind, 'photo');
    expect(back.replyTo!.text, isNull);
    expect(back.caption, 'hi');
  });

  test('AudioContent round-trips a replyTo', () {
    final enc = const AudioContent(
      sampleDesc,
      replyTo: ReplyRef(id: 'm3', author: 'court', kind: 'voice'),
    ).encode();
    final back = MessageContent.decode(enc) as AudioContent;
    expect(back.replyTo!.id, 'm3');
    expect(back.replyTo!.kind, 'voice');
  });

  test('a v1 envelope without replyTo still decodes (back-compat)', () {
    final back = MessageContent.decode(const TextContent('hi').encode());
    expect((back as TextContent).replyTo, isNull);
  });
}
