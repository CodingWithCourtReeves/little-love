import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/profile/profile_envelope.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

  test('round-trips display name with no avatar', () async {
    final env = await encodeProfileEnvelope(
      key,
      const ProfileData(displayName: 'Ali 🌹', avatar: null),
    );
    expect(env, isNotEmpty);
    final back = await decodeProfileEnvelope(key, env);
    expect(back!.displayName, 'Ali 🌹');
    expect(back.avatar, isNull);
  });

  test('decode returns null under a wrong key', () async {
    final env = await encodeProfileEnvelope(
      key,
      const ProfileData(displayName: 'x', avatar: null),
    );
    final wrong = Uint8List.fromList(List<int>.generate(32, (i) => 99 - i));
    expect(await decodeProfileEnvelope(wrong, env), isNull);
  });
}
