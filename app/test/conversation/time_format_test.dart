import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/time_format.dart';

void main() {
  // Thursday, Oct 29 2026, 9:41 PM local.
  final now = DateTime(2026, 10, 29, 21, 41);

  group('clockTime', () {
    test('a 12-hour device gets h:mm with AM/PM', () {
      expect(
        clockTime(DateTime(2026, 10, 29, 21, 41), use24h: false),
        '9:41 PM',
      );
      expect(
        clockTime(DateTime(2026, 10, 29, 0, 5), use24h: false),
        '12:05 AM',
      );
      expect(
        clockTime(DateTime(2026, 10, 29, 12, 0), use24h: false),
        '12:00 PM',
      );
    });

    test('a 24-hour device gets zero-padded HH:mm', () {
      expect(clockTime(DateTime(2026, 10, 29, 21, 41), use24h: true), '21:41');
      expect(clockTime(DateTime(2026, 10, 29, 9, 3), use24h: true), '09:03');
      expect(clockTime(DateTime(2026, 10, 29, 0, 5), use24h: true), '00:05');
    });
  });

  group('listTimeLabel', () {
    test('a 24-hour device sees the 24-hour clock for today', () {
      expect(
        listTimeLabel(DateTime(2026, 10, 29, 21, 38), now: now, use24h: true),
        '21:38',
      );
    });

    test('today shows the 12-hour clock time', () {
      expect(
        listTimeLabel(DateTime(2026, 10, 29, 21, 38), now: now, use24h: false),
        '9:38 PM',
      );
      expect(
        listTimeLabel(DateTime(2026, 10, 29, 0, 5), now: now, use24h: false),
        '12:05 AM',
      );
      expect(
        listTimeLabel(DateTime(2026, 10, 29, 12, 0), now: now, use24h: false),
        '12:00 PM',
      );
    });

    test('yesterday says Yesterday, even just before midnight', () {
      expect(
        listTimeLabel(DateTime(2026, 10, 28, 23, 59), now: now, use24h: false),
        'Yesterday',
      );
    });

    test('within the last week shows the weekday', () {
      expect(
        listTimeLabel(DateTime(2026, 10, 27, 8), now: now, use24h: false),
        'Tuesday',
      );
      expect(
        listTimeLabel(DateTime(2026, 10, 23, 8), now: now, use24h: false),
        'Friday',
      );
    });

    test('a week or more back shows the date, adding the year when it '
        'is not this year', () {
      expect(
        listTimeLabel(DateTime(2026, 10, 22, 8), now: now, use24h: false),
        'Oct 22',
      );
      expect(
        listTimeLabel(DateTime(2026, 1, 3), now: now, use24h: false),
        'Jan 3',
      );
      expect(
        listTimeLabel(DateTime(2025, 3, 14), now: now, use24h: false),
        'Mar 14, 2025',
      );
    });
  });

  group('dayLabel', () {
    test('today and yesterday by name', () {
      expect(dayLabel(DateTime(2026, 10, 29), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 10, 28), now: now), 'Yesterday');
    });

    test('yesterday holds across a month boundary', () {
      expect(
        dayLabel(DateTime(2026, 10, 31), now: DateTime(2026, 11, 1, 9)),
        'Yesterday',
      );
    });
  });
}
