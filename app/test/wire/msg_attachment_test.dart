import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  test('attachment defaults to null and survives copyWith', () {
    final m = Msg(
      id: '1',
      from: 'court',
      to: 'r',
      body: '',
      ts: DateTime.now(),
    );
    expect(m.attachment, isNull);
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
    final withAtt = Msg(
      id: '1',
      from: 'court',
      to: 'r',
      body: '',
      ts: m.ts,
      attachment: d,
    );
    expect(withAtt.copyWith(sendStatus: SendStatus.sent).attachment, isNotNull);
  });
}
