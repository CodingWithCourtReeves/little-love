import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/channel_order.dart';
import 'package:littlelove/inbox/room.dart';

Room _channel(String id, {required int createdDay}) => Room(
  roomId: id,
  name: id,
  members: const [],
  createdAt: DateTime.utc(2026, 10, createdDay),
);

List<String> _ids(List<Room> rooms) => [for (final r in rooms) r.roomId];

void main() {
  test('the channel with the newest message comes first', () {
    final latest = {
      'date-night': DateTime.utc(2026, 10, 29, 20, 15),
      'groceries': DateTime.utc(2026, 10, 29, 18, 2),
      'trip-to-lisbon': DateTime.utc(2026, 10, 29, 21, 41),
    };
    final order = channelsByActivity([
      _channel('date-night', createdDay: 1),
      _channel('groceries', createdDay: 2),
      _channel('trip-to-lisbon', createdDay: 3),
    ], (id) => latest[id]);
    expect(_ids(order), ['trip-to-lisbon', 'date-night', 'groceries']);
  });

  test('a channel with no messages sorts by when it was created, so a new '
      'one starts near the top', () {
    final latest = {'date-night': DateTime.utc(2026, 10, 20)};
    final order = channelsByActivity([
      _channel('date-night', createdDay: 1),
      _channel('anniversary-ideas', createdDay: 29),
      _channel('house-hunting', createdDay: 3),
    ], (id) => latest[id]);
    expect(_ids(order), ['anniversary-ideas', 'date-night', 'house-hunting']);
  });

  test('ties break on creation time, then room id, so the order is stable', () {
    final same = DateTime.utc(2026, 10, 29, 12);
    final order = channelsByActivity([
      _channel('b', createdDay: 1),
      _channel('a', createdDay: 1),
      _channel('c', createdDay: 2),
    ], (_) => same);
    expect(_ids(order), ['c', 'a', 'b']);
  });
}
