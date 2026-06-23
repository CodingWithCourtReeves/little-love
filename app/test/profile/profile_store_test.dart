import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/profile/profile_store.dart';

void main() {
  PartnerProfile p(String name, DateTime t) => PartnerProfile(
    username: 'bob',
    displayName: name,
    avatar: null,
    updatedAt: t,
  );

  test('apply stores and reads back by username', () {
    final s = ProfileStore();
    s.apply(p('Bob', DateTime.utc(2026, 1, 1)));
    expect(s.forUsername('bob')!.displayName, 'Bob');
    expect(s.forUsername('nobody'), isNull);
  });

  test('latest updatedAt wins; stale update ignored', () {
    final s = ProfileStore();
    s.apply(p('New', DateTime.utc(2026, 1, 2)));
    s.apply(p('Old', DateTime.utc(2026, 1, 1))); // earlier → ignored
    expect(s.forUsername('bob')!.displayName, 'New');
  });

  test('notifies listeners on real change', () {
    final s = ProfileStore();
    var n = 0;
    s.addListener(() => n++);
    s.apply(p('Bob', DateTime.utc(2026, 1, 1)));
    expect(n, 1);
  });
}
