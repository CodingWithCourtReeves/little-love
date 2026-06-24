import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/last_seen_label.dart';

void main() {
  // Local wall-clock anchors so the "today/yesterday" calendar logic is
  // deterministic regardless of the test machine's zone.
  final now = DateTime(2026, 6, 24, 15, 0); // Wed 3:00 PM local

  test('under a minute -> just now', () {
    expect(
      lastSeenLabel(now.subtract(const Duration(seconds: 30)), now: now),
      'last seen just now',
    );
  });

  test('minutes ago (singular + plural)', () {
    expect(
      lastSeenLabel(now.subtract(const Duration(minutes: 1)), now: now),
      'last seen 1 minute ago',
    );
    expect(
      lastSeenLabel(now.subtract(const Duration(minutes: 5)), now: now),
      'last seen 5 minutes ago',
    );
  });

  test('earlier today -> today at time', () {
    final t = DateTime(2026, 6, 24, 9, 14); // same day, >1h ago
    expect(lastSeenLabel(t, now: now), 'last seen today at 9:14 AM');
  });

  test('previous day -> yesterday at time', () {
    final t = DateTime(2026, 6, 23, 21, 14);
    expect(lastSeenLabel(t, now: now), 'last seen yesterday at 9:14 PM');
  });

  test('within the past week -> weekday at time', () {
    final t = DateTime(2026, 6, 21, 21, 14); // Sun
    expect(lastSeenLabel(t, now: now), 'last seen Sunday at 9:14 PM');
  });

  test('older than a week -> date', () {
    final t = DateTime(2026, 6, 10, 21, 14);
    expect(lastSeenLabel(t, now: now), 'last seen 06/10/2026');
  });

  test('midnight formats as 12:mm AM', () {
    final t = DateTime(2026, 6, 24, 0, 5);
    expect(lastSeenLabel(t, now: now), 'last seen today at 12:05 AM');
  });

  test('noon formats as 12:mm PM', () {
    // Anchor "now" later so noon is >1h ago but still today.
    final lateNow = DateTime(2026, 6, 24, 20, 0);
    final t = DateTime(2026, 6, 24, 12, 0);
    expect(lastSeenLabel(t, now: lateNow), 'last seen today at 12:00 PM');
  });
}
