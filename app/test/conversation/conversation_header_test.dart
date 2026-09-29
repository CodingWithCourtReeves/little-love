import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/presence_state.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';

import '../support/test_read_state.dart';

Room _room() => Room(
  roomId: 'r1',
  name: '',
  members: const [
    Member(username: 'me', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 13),
);

final _account = LocalAccount(
  username: 'me',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 13),
);

void main() {
  testWidgets('the chat header has no call buttons (calls live in chat info)', (
    tester,
  ) async {
    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
      ],
    );
    addTearDown(c.dispose);
    await c.read(accountProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _room(),
            selfUsername: 'me',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('video-call-button')), findsNothing);
    expect(find.byKey(const Key('call-button')), findsNothing);
    expect(find.byKey(const Key('room-header-avatar')), findsOneWidget);
  });

  testWidgets('a long "last seen" line truncates instead of overflowing the '
      'title pill on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
      ],
    );
    addTearDown(c.dispose);
    await c.read(accountProvider.future);
    final now = DateTime.now();
    // Three days back at 12:59 PM: "last seen <weekday> at 12:59 PM".
    final seen = DateTime(now.year, now.month, now.day - 3, 12, 59);
    c.read(presenceProvider('kaitlyn').notifier).set(false, lastSeen: seen);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: MediaQuery(
            // Larger accessibility text makes the line as wide as it gets.
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.4),
            ),
            child: ConversationPage(
              room: _room(),
              selfUsername: 'me',
              onSend: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('presence-indicator')),
        matching: find.byType(Text),
      ),
    );
    expect(label.data, startsWith('last seen '));
    expect(label.overflow, TextOverflow.ellipsis);
    expect(label.maxLines, 1);
  });
}
