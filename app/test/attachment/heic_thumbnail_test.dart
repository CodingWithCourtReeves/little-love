import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:littlelove/attachment/thumbnail.dart';

// Diagnostic: iOS Photos delivers HEIC. If the `image` package can't decode it,
// buildImageThumbnail throws before any upload — matching the observed
// "selected image, nothing happened" with no blob PUT reaching the server.
void main() {
  test('image package cannot decode a real HEIC (root-cause check)', () {
    final bytes = File('test/fixtures/sample.heic').readAsBytesSync();
    expect(
      img.decodeImage(bytes),
      isNull,
      reason: 'if this is non-null, the image package CAN decode HEIC',
    );
  });

  test('buildImageThumbnail throws on HEIC bytes', () async {
    final bytes = File('test/fixtures/sample.heic').readAsBytesSync();
    expect(() => buildImageThumbnail(bytes), throwsA(isA<Exception>()));
  });
}
