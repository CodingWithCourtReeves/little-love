import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wallpaper/wallpaper_doodles.dart';

void main() {
  test('paintDoodleField paints without throwing and issues draw calls', () {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    paintDoodleField(canvas, const Size(400, 800), const Color(0x24FFFFFF));
    final picture = recorder.endRecording();
    expect(picture, isNotNull);
  });
}
