import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';

void main() {
  test('json round-trips, omitting null video fields for images', () {
    const d = AttachmentDescriptor(
      blobKey: '01JBLOB', contentKeyB64: 'a', nonceB64: 'b',
      mime: 'image/jpeg', filename: 'IMG.jpg', size: 5242880,
      width: 4032, height: 3024, durationMs: null, thumbB64: 'tt',
    );
    final j = d.toJson();
    expect(j.containsKey('duration_ms'), isFalse);
    final back = AttachmentDescriptor.fromJson(j);
    expect(back.blobKey, '01JBLOB');
    expect(back.isVideo, isFalse);
  });

  test('isVideo true for video mime', () {
    const d = AttachmentDescriptor(
      blobKey: 'k', contentKeyB64: 'a', nonceB64: 'b', mime: 'video/mp4',
      filename: 'v.mp4', size: 10, width: 1, height: 1, durationMs: 8200, thumbB64: 't');
    expect(d.isVideo, isTrue);
    expect(d.toJson()['duration_ms'], 8200);
  });

  test('thumb encode/decode round-trips', () async {
    final plain = Uint8List.fromList([9, 8, 7, 6, 5]);
    final wire = await encodeThumb(plain);
    final out = await decodeThumb(wire);
    expect(out, equals(plain));
  });
}
