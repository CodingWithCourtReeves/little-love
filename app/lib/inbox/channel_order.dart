import 'room.dart';

/// [channels] in home-list order: the most recent activity first, the way chat
/// lists order conversations, so a channel that just got a message rises to
/// the top.
///
/// A channel's activity is its latest message's time ([latestAt]; reactions,
/// edits and unsends are applied onto rows, so they never count). A channel
/// with no messages uses its creation time instead, so one you just made
/// starts near the top. Ties break on creation time, then room id, so the
/// order is stable between rebuilds.
List<Room> channelsByActivity(
  Iterable<Room> channels,
  DateTime? Function(String roomId) latestAt,
) {
  DateTime activity(Room r) => latestAt(r.roomId) ?? r.createdAt;
  return channels.toList()..sort((a, b) {
    final byActivity = activity(b).compareTo(activity(a));
    if (byActivity != 0) return byActivity;
    final byCreated = b.createdAt.compareTo(a.createdAt);
    if (byCreated != 0) return byCreated;
    return a.roomId.compareTo(b.roomId);
  });
}
