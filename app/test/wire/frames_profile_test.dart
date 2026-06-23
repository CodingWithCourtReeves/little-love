import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  test('parses Profile frame', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'Profile',
      'user': 'alice',
      'envelope': 'ZW52',
      'avatar_key': 'blob-1',
    });
    expect(f, isA<ProfileFrame>());
    f as ProfileFrame;
    expect(f.user, 'alice');
    expect(f.envelopeB64, 'ZW52');
    expect(f.avatarKey, 'blob-1');
  });

  test('Profile frame tolerates missing avatar_key', () {
    final f = RoomServerFrame.fromJson(
            {'kind': 'Profile', 'user': 'bob', 'envelope': 'ZW52'})
        as ProfileFrame;
    expect(f.avatarKey, isNull);
  });

  test('PublishProfileFrame serializes', () {
    final json =
        PublishProfileFrame(envelopeB64: 'ZW52', avatarKey: 'blob-2').toJson();
    expect(json, {
      'kind': 'PublishProfile',
      'envelope': 'ZW52',
      'avatar_key': 'blob-2',
    });
  });
}
