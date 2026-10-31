import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/attachment/square_image.dart';

void main() {
  test('squareJpeg centre-crops to a 512 square', () {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 800, height: 400)),
    );
    final out = img.decodeJpg(squareJpeg(png))!;
    expect(out.width, 512);
    expect(out.height, 512);
  });

  test('squareJpeg rejects undecodable bytes with a FormatException', () {
    expect(
      () => squareJpeg(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
