import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/wire/frames.dart';

Member m(String u) => Member(
    username: u, ed25519PubBase64: '', x25519PubBase64: '',
    isBot: false, ownerUsername: null);

void main() {
  testWidgets('conversation header renders the channel switcher pill',
      (t) async {
    final room = Room(
      roomId: 'p', name: '',
      members: [m('court'), m('kaitlyn')],
      createdAt: DateTime.utc(2026, 6, 14),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([room]);
    container.read(inboxStateProvider.notifier).select('p');
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ConversationPage(
          room: room,
          selfUsername: 'court',
          onSend: (_) {},
        ),
      ),
    ));
    await t.pump();
    expect(find.byKey(const Key('channel-switcher-pill')), findsOneWidget);
  });
}
