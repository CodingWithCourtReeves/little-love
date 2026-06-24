import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

import '../support/test_read_state.dart';

Room _room(String id) => Room(
  roomId: id,
  name: 'Test',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'e', x25519PubBase64: 'x'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

void main() {
  testWidgets('ConversationPage sets activeRoom on mount, clears on dispose', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: [hermeticReadStateStore()]);
    addTearDown(container.dispose);

    expect(container.read(activeRoomProvider), isNull);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ConversationPage(
            room: _room('room1'),
            selfUsername: 'court',
            onSend: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(); // let the post-frame callback run

    expect(container.read(activeRoomProvider), 'room1');

    // Replace the page so ConversationPage disposes.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold()),
      ),
    );
    await tester.pump();

    expect(container.read(activeRoomProvider), isNull);
  });
}
