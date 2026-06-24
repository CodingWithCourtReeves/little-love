/// Telegram-style "last seen …" text for an offline partner. Pure function:
/// pass `now` so it is deterministic and testable. Compares in local time.
String lastSeenLabel(DateTime lastSeen, {required DateTime now}) {
  final seen = lastSeen.toLocal();
  final n = now.toLocal();
  final diff = n.difference(seen);

  if (diff.inMinutes < 1) return 'last seen just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return 'last seen $m ${m == 1 ? 'minute' : 'minutes'} ago';
  }

  final today = DateTime(n.year, n.month, n.day);
  final seenDay = DateTime(seen.year, seen.month, seen.day);
  final daysApart = today.difference(seenDay).inDays;
  final time = _time(seen);

  if (daysApart == 0) return 'last seen today at $time';
  if (daysApart == 1) return 'last seen yesterday at $time';
  if (daysApart < 7) return 'last seen ${_weekday(seen.weekday)} at $time';

  final mm = seen.month.toString().padLeft(2, '0');
  final dd = seen.day.toString().padLeft(2, '0');
  return 'last seen $mm/$dd/${seen.year}';
}

String _time(DateTime t) {
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  var h = t.hour % 12;
  if (h == 0) h = 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m $ampm';
}

String _weekday(int w) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][w - 1];
