import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/attachment/thumbnail.dart';

void main() {
  test(
    'downscales a large image to <=360px long edge, returns jpeg + dims',
    () async {
      final src = img.Image(width: 1200, height: 800);
      img.fill(src, color: img.ColorRgb8(120, 60, 90));
      final png = Uint8List.fromList(img.encodePng(src));

      final t = await buildImageThumbnail(png);
      expect(t.width, 1200);
      expect(t.height, 800);
      final decoded = img.decodeJpg(t.jpeg)!;
      expect(decoded.width <= 360 && decoded.height <= 360, isTrue);
      expect(decoded.width, 360); // long edge clamped
    },
  );

  test('keeps the encoded thumbnail under the wire byte budget', () async {
    // A noisy image is the worst case for JPEG size; the adaptive quality
    // loop must still bring it under budget so a Send never trips the
    // server's body cap.
    final src = img.Image(width: 1600, height: 1200);
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        src.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x * y) % 256);
      }
    }
    final png = Uint8List.fromList(img.encodePng(src));
    final t = await buildImageThumbnail(png);
    expect(t.jpeg.length, lessThanOrEqualTo(44 * 1024));
  });
}
