import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/attachment/thumbnail.dart';

void main() {
  test('downscales a large image to <=180px long edge, returns jpeg + dims', () async {
    final src = img.Image(width: 1200, height: 800);
    img.fill(src, color: img.ColorRgb8(120, 60, 90));
    final png = Uint8List.fromList(img.encodePng(src));

    final t = await buildImageThumbnail(png);
    expect(t.width, 1200);
    expect(t.height, 800);
    final decoded = img.decodeJpg(t.jpeg)!;
    expect(decoded.width <= 180 && decoded.height <= 180, isTrue);
    expect(decoded.width, 180); // long edge clamped
  });
}
