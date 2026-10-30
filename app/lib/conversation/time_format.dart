/// Shared date and time wording for the chat and the home list, so a day
/// separator in a conversation and a row's time on the home screen always use
/// the same vocabulary ("Yesterday", "Tuesday", "Oct 3", "Mar 14, 2025").
library;

/// Midnight of [dt]'s calendar day, in [dt]'s own zone.
DateTime dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

/// 12-hour clock time, e.g. "9:41 PM".
String clockTime(DateTime t) {
  final h = t.hour == 0 ? 12 : (t.hour > 12 ? t.hour - 12 : t.hour);
  final m = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  return '$h:$m $ampm';
}

String weekdayName(int weekday) {
  const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return names[weekday - 1];
}

String monthName(int month) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return names[month - 1];
}

/// A calendar day relative to [now]: "Today", "Yesterday", the weekday within
/// the last week, then "Oct 3", adding the year once it isn't this year.
/// [day] and [now] are local times; only their dates matter.
String dayLabel(DateTime day, {required DateTime now}) {
  final d = dateOnly(day);
  final today = dateOnly(now);
  if (d == today) return 'Today';
  // Whole-day steps via the calendar fields and UTC, not Duration(days: 1)
  // on local times, so a DST change (a 23- or 25-hour day) can't shift them.
  if (d == DateTime(today.year, today.month, today.day - 1)) {
    return 'Yesterday';
  }
  final diff = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
  if (diff > 0 && diff < 7) return weekdayName(d.weekday);
  if (d.year == today.year) return '${monthName(d.month)} ${d.day}';
  return '${monthName(d.month)} ${d.day}, ${d.year}';
}

/// The time shown on a home-screen row: the clock time for today's messages,
/// otherwise the [dayLabel] ("Yesterday", "Tuesday", "Oct 3", ...).
String listTimeLabel(DateTime t, {required DateTime now}) =>
    dateOnly(t) == dateOnly(now) ? clockTime(t) : dayLabel(t, now: now);
