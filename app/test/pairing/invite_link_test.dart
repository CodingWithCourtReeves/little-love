import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/pairing/invite_link.dart';

void main() {
  test('pairLink builds the https universal link', () {
    expect(
      pairLink('abandon-pilot-react-zoo'),
      'https://littlelove.dev/pair/abandon-pilot-react-zoo',
    );
  });

  test('extractPairCode round-trips a pair link', () {
    final code = extractPairCode(
      Uri.parse('https://littlelove.dev/pair/abandon-pilot-react-zoo'),
    );
    expect(code, 'abandon-pilot-react-zoo');
  });

  test('extractPairCode returns null for a non-pair path', () {
    expect(extractPairCode(Uri.parse('https://littlelove.dev/health')), isNull);
    expect(extractPairCode(Uri.parse('https://littlelove.dev/pair/')), isNull);
  });
}
