import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/glare.dart';

void main() {
  test('the smaller username wins', () {
    expect(glareIWin('court', 'kaitlyn'), isTrue);
    expect(glareIWin('kaitlyn', 'court'), isFalse);
  });

  test('both sides converge on the same winner (anti-symmetry)', () {
    // For any distinct pair, exactly one side wins.
    expect(glareIWin('alice', 'bob'), isNot(glareIWin('bob', 'alice')));
    expect(glareIWin('zoe', 'amy'), isNot(glareIWin('amy', 'zoe')));
  });

  test('equal usernames do not both claim victory', () {
    // Degenerate (never happens for a couple) but must not deadlock.
    expect(glareIWin('same', 'same'), isFalse);
  });

  test('ring timeout is 35s', () {
    expect(callRingTimeout, const Duration(seconds: 35));
  });
}
