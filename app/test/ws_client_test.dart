import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/ws_client.dart';

void main() {
  test('LinearBackoff yields 1, 2, 5, 10, 15, 15... seconds', () {
    final b = LinearBackoff();
    expect(b.next().inSeconds, 1);
    expect(b.next().inSeconds, 2);
    expect(b.next().inSeconds, 5);
    expect(b.next().inSeconds, 10);
    expect(b.next().inSeconds, 15);
    expect(b.next().inSeconds, 15);
    b.reset();
    expect(b.next().inSeconds, 1);
  });
}
