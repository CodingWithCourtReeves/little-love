import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/theme/twilight.dart';

void main() {
  test('familiar bubble tint constants exist (sage family)', () {
    expect(TwilightColors.bubbleFamiliarBg, const Color(0xFFEFEDDF));
    expect(TwilightColors.bubbleFamiliarBorder, const Color(0xFFDFDCC4));
  });
}
