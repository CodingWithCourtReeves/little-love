import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Room _r(String id, String peer) => Room(
  roomId: id,
  name: '',
  members: [
    const Member(username: 'court', ed25519PubBase64: '', x25519PubBase64: ''),
    Member(username: peer, ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
  ],
  createdAt: DateTime.utc(2026, 6, 9),
);

void main() {
  test('initial state has no rooms', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(inboxStateProvider).rooms, isEmpty);
  });

  test('setRooms replaces the room list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final rooms = [_r('1', 'kaitlyn'), _r('2', 'sage')];
    container.read(inboxStateProvider.notifier).setRooms(rooms);
    expect(container.read(inboxStateProvider).rooms, rooms);
    container.read(inboxStateProvider.notifier).setRooms([_r('2', 'sage')]);
    expect(container.read(inboxStateProvider).rooms.single.roomId, '2');
  });

  test('renameRoom updates the name in place', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    container.read(inboxStateProvider.notifier).renameRoom('1', 'Daily');
    expect(container.read(inboxStateProvider).rooms.single.name, 'Daily');
  });

  test('removeMember drops the member, and the room when none remain', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    // Removing the partner leaves only court.
    container.read(inboxStateProvider.notifier).removeMember('1', 'kaitlyn');
    expect(
      container.read(inboxStateProvider).rooms.single.members.single.username,
      'court',
    );
    // Removing the last member removes the room entirely.
    container.read(inboxStateProvider.notifier).removeMember('1', 'court');
    expect(container.read(inboxStateProvider).rooms, isEmpty);
  });
}
