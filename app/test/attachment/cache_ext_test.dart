import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/attachment/attachment_download.dart';

AttachmentDescriptor _d({required String mime, String filename = ''}) =>
    AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: 'c',
      nonceB64: 'n',
      mime: mime,
      filename: filename,
      size: 1,
      width: 0,
      height: 0,
      durationMs: null,
      thumbB64: '',
    );

void main() {
  test('audio/mp4 maps to .m4a', () {
    expect(cacheExtFor(_d(mime: 'audio/mp4')), '.m4a');
  });

  test('explicit filename extension still wins', () {
    expect(cacheExtFor(_d(mime: 'audio/mp4', filename: 'note.aac')), '.aac');
  });
}
