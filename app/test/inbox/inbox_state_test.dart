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
  test('initial state has no rooms and no selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = container.read(inboxStateProvider);
    expect(s.rooms, isEmpty);
    expect(s.selectedRoomId, isNull);
  });

  test('setRooms replaces the room list', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final rooms = [_r('1', 'kaitlyn'), _r('2', 'sage')];
    container.read(inboxStateProvider.notifier).setRooms(rooms);
    expect(container.read(inboxStateProvider).rooms, rooms);
  });

  test('select sets selectedRoomId when the room exists', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    container.read(inboxStateProvider.notifier).select('1');
    expect(container.read(inboxStateProvider).selectedRoomId, '1');
  });

  test('select throws for an unknown roomId', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    expect(
      () =>
          container.read(inboxStateProvider.notifier).select('does-not-exist'),
      throwsArgumentError,
    );
  });

  test('setRooms clears selection if the previously selected room is gone', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_r('1', 'kaitlyn')]);
    container.read(inboxStateProvider.notifier).select('1');
    container.read(inboxStateProvider.notifier).setRooms([_r('2', 'sage')]);
    expect(container.read(inboxStateProvider).selectedRoomId, isNull);
  });
}
