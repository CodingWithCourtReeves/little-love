import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/callkit_accepted.dart';

void main() {
  test('finds an accepted call by id', () {
    final calls = [
      {'id': 'other', 'isAccepted': true},
      {'id': 'c1', 'isAccepted': true},
    ];
    expect(callKitAccepted(calls, 'c1'), isTrue);
  });

  test('the plugin also reports a connected call as accepted', () {
    expect(
      callKitAccepted([
        {'id': 'c1', 'isAccepted': false, 'accepted': true},
      ], 'c1'),
      isTrue,
    );
  });

  test('a ringing call is not accepted', () {
    expect(
      callKitAccepted([
        {'id': 'c1', 'isAccepted': false, 'accepted': false},
      ], 'c1'),
      isFalse,
    );
  });

  test('ids match case-insensitively (CallKit uppercases UUIDs)', () {
    expect(
      callKitAccepted([
        {'id': 'ABC-1', 'isAccepted': true},
      ], 'abc-1'),
      isTrue,
    );
  });

  test('garbage is not accepted', () {
    expect(callKitAccepted(null, 'c1'), isFalse);
    expect(callKitAccepted('nope', 'c1'), isFalse);
    expect(callKitAccepted([42, null], 'c1'), isFalse);
  });
}
