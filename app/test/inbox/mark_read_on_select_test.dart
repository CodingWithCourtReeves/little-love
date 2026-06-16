import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/inbox/select_room.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Member m(String u) => Member(
  username: u,
  ed25519PubBase64: '',
  x25519PubBase64: '',
);

void main() {
  test('selectAndMarkRead selects the room and clears its unread', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final room = Room(
      roomId: 'room-a',
      name: '',
      members: [m('court'), m('kaitlyn')],
      createdAt: DateTime.utc(2026, 6, 14),
    );
    c.read(inboxStateProvider.notifier).setRooms([room]);
    c
        .read(messageStoreProvider('room-a').notifier)
        .add(
          Msg(
            id: 'm1',
            from: 'kaitlyn',
            to: 'room-a',
            body: 'hi',
            ts: DateTime.utc(2026, 6, 14, 12),
          ),
        );
    // Activate the provider so it tracks dependencies and re-evaluates.
    c.listen(roomUnreadProvider('room-a'), (_, _) {});
    expect(c.read(roomUnreadProvider('room-a')), isTrue);

    selectAndMarkRead(c, 'room-a');

    expect(c.read(inboxStateProvider).selectedRoomId, 'room-a');
    expect(c.read(roomUnreadProvider('room-a')), isFalse);
  });
}
