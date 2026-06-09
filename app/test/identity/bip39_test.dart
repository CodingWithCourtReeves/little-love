import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/identity/bip39.dart';

void main() {
  test('seedToPhrase / phraseToSeed round-trips a 16-byte seed', () {
    final seed = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final phrase = seedToPhrase(seed);
    expect(phrase.split(' ').length, 12);
    expect(phraseToSeed(phrase), equals(seed));
  });

  test('generateSeed returns 16 bytes (128-bit entropy → 12 words)', () {
    final s = generateSeed();
    expect(s.length, 16);
  });

  test('phraseToSeed rejects an 11-word phrase', () {
    final eleven = List<String>.filled(11, 'abandon').join(' ');
    expect(() => phraseToSeed(eleven), throwsA(isA<FormatException>()));
  });

  test('phraseToSeed rejects a phrase with an invalid word', () {
    final bad = ('${'abandon ' * 11}notarealword').trim();
    expect(() => phraseToSeed(bad), throwsA(isA<FormatException>()));
  });
}
