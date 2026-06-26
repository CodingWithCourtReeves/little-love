import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/chat_info_page.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/link_preview.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/presence_state.dart';
import 'package:littlelove/conversation/typing_state.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wallpaper/wallpaper_background.dart';
import 'package:littlelove/wallpaper/wallpaper_controller.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

Room _roomA() => Room(
  roomId: 'roomA',
  name: 'Kaitlyn',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
    ),
  ],
  createdAt: DateTime.utc(2026, 6, 9),
);

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 6, 9),
);

// ConversationPage now watches unread-elsewhere (for the back-button badge),
// which hydrates the read-state store. Point it at an empty temp dir so tests
// stay hermetic instead of reading the dev machine's real read_state.json.
final _readStateStore = ReadStateStore(
  homeDirectory: Directory.systemTemp.createTempSync('conv_test_rs'),
);

void main() {
  testWidgets('renders inbound and outbound bubbles distinctly', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'long. miss you.',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hey love'), findsOneWidget);
    expect(find.text('long. miss you.'), findsOneWidget);
    // The AppBar now shows the room name in place of the channel switcher.
    expect(find.text('Kaitlyn'), findsOneWidget);
    // Each text bubble paints its own tailed background (a CustomPaint keyed
    // by message id) — one for the partner's, one for mine.
    expect(find.byKey(const Key('bubble-bg-1')), findsOneWidget);
    expect(find.byKey(const Key('bubble-bg-2')), findsOneWidget);
  });

  testWidgets('renders a link-preview card for a message that has one', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'look https://example.com',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
        linkPreview: const LinkPreview(
          url: 'https://example.com',
          title: 'Example Title',
          description: 'Some description',
          siteName: 'Example',
        ),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-preview-card')), findsOneWidget);
    expect(find.text('Example Title'), findsOneWidget);
    expect(find.text('Some description'), findsOneWidget);
  });

  testWidgets('tapping send button fires onSend', (tester) async {
    String? sent;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (t, _) => sent = t,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.pump(); // send button appears once there's text
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    expect(sent, 'hi');
  });

  testWidgets('renders a wallpaper and a send bumps the drift', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WallpaperBackground), findsOneWidget);

    final before = container.read(wallpaperDriftProvider);
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    expect(container.read(wallpaperDriftProvider), before + 1);
  });

  testWidgets('composer floats as frosted glass (has BackdropFilters)', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Two frosted surfaces in the composer: the pill and the idle mic glass
    // circle (shown while the field is empty). The top scrim also frosts now
    // (its own stacked blur bands), so scope the count to BackdropFilters that
    // are NOT part of the top scrim.
    final all = find.byType(BackdropFilter).evaluate().length;
    final inScrim = find
        .descendant(
          of: find.byKey(const Key('top-scrim')),
          matching: find.byType(BackdropFilter),
        )
        .evaluate()
        .length;
    expect(all - inScrim, 2);
  });

  testWidgets('tapping the room-name pill opens the chat-info page', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('room-title-pill')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatInfoPage), findsOneWidget);
  });

  testWidgets('title pill shows partner presence (offline → online)', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Default: the partner (kaitlyn) reads as offline.
    expect(
      find.descendant(
        of: find.byKey(const Key('room-title-pill')),
        matching: find.text('offline'),
      ),
      findsOneWidget,
    );

    // Partner comes online → the line flips.
    container.read(presenceProvider('kaitlyn').notifier).set(true);
    await tester.pump();
    expect(find.text('online'), findsOneWidget);
    expect(find.text('offline'), findsNothing);

    // Goes offline with a last-seen → Telegram-style "last seen …" text.
    container
        .read(presenceProvider('kaitlyn').notifier)
        .set(
          false,
          lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
        );
    await tester.pump();
    expect(find.text('online'), findsNothing);
    expect(find.text('last seen 5 minutes ago'), findsOneWidget);

    // Offline with no last-seen → bare "offline" fallback.
    container.read(presenceProvider('kaitlyn').notifier).set(false);
    await tester.pump();
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('partner typing shows a typing line inside the title pill', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('typing-indicator')), findsNothing);

    // Partner starts typing → the line appears nested in the title pill.
    container.read(typingProvider('roomA').notifier).setTyping(true);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('room-title-pill')),
        matching: find.byKey(const Key('typing-indicator')),
      ),
      findsOneWidget,
    );

    // Stop typing (also cancels the safety-timeout timer).
    container.read(typingProvider('roomA').notifier).setTyping(false);
    await tester.pump();
    expect(find.byKey(const Key('typing-indicator')), findsNothing);
  });

  testWidgets('trailing button morphs mic <-> send with content', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Empty composer: mic affordance shown, send hidden.
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    expect(find.byKey(const Key('composer-send')), findsNothing);

    // With text: send shown, mic gone.
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
    expect(find.byKey(const Key('composer-mic')), findsNothing);

    // Cleared again: morphs back to mic.
    await tester.enterText(find.byKey(const Key('composer')), '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-mic')), findsOneWidget);
    expect(find.byKey(const Key('composer-send')), findsNothing);
  });

  testWidgets('long-press my own message offers Copy + Delete; Delete fires', (
    tester,
  ) async {
    String? deletedId;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (id) => deletedId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hey love'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('action-copy')), findsOneWidget);
    expect(find.byKey(const Key('action-delete')), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-delete')));
    await tester.pumpAndSettle();
    expect(deletedId, '2');
  });

  testWidgets('long-press a stuck sending message cancels, not unsends', (
    tester,
  ) async {
    String? unsentId;
    String? cancelledClientId;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: 'cli-9',
        from: 'court',
        to: 'kaitlyn',
        body: 'still going',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
        clientMsgId: 'cli-9',
        sendStatus: SendStatus.sending,
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (id) => unsentId = id,
            onCancelSend: (id) => cancelledClientId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('still going'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-delete')), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-delete')));
    await tester.pumpAndSettle();
    // An unconfirmed send has no shared id to unsend — it's a local cancel.
    expect(cancelledClientId, 'cli-9');
    expect(unsentId, isNull);
  });

  testWidgets('edit my own message: enter edit mode, prefill, fire onEdit', (
    tester,
  ) async {
    String? editedId;
    String? editedText;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (_) {},
            onEdit: (id, text) {
              editedId = id;
              editedText = text;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hey love'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('action-edit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();

    // Edit mode: a banner appears and the composer is prefilled with the text.
    expect(find.byKey(const Key('edit-banner')), findsOneWidget);
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('composer')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, 'hey love');

    // Correct the text and send → fires onEdit, not onSend.
    await tester.enterText(find.byKey(const Key('composer')), 'hey babe');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();

    expect(editedId, '2');
    expect(editedText, 'hey babe');
    // Edit mode exits after sending.
    expect(find.byKey(const Key('edit-banner')), findsNothing);
  });

  testWidgets('cancelling edit mode restores normal compose', (tester) async {
    String? editedId;
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (_) {},
            onEdit: (id, _) => editedId = id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('hey love'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-banner')), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-banner')), findsNothing);
    expect(editedId, isNull);
  });

  testWidgets('an edited message renders an "edited" marker', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'fixed text',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
        edited: true,
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('edited'), findsOneWidget);
  });

  testWidgets('long-press a partner message offers no Edit', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'miss you',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (_) {},
            onEdit: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('miss you'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('action-edit')),
      findsNothing,
      reason: "can't edit the partner's message",
    );
  });

  testWidgets('long-press a partner message offers Copy but not Delete', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    container.read(inboxStateProvider.notifier).setRooms([_roomA()]);
    container.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'miss you',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onReact: (_, _) {},
            onDelete: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('miss you'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('action-copy')), findsOneWidget);
    expect(
      find.byKey(const Key('action-delete')),
      findsNothing,
      reason: "can't unsend the partner's message for everyone",
    );
  });

  testWidgets('back button badges unread waiting in other rooms', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('conv_badge_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(
          ReadStateStore(homeDirectory: tmp),
        ),
      ],
    );
    addTearDown(container.dispose);
    // The room on screen plus a second thread with an unread partner message.
    final roomB = Room(
      roomId: 'roomB',
      name: 'Date ideas',
      members: _roomA().members,
      createdAt: DateTime.utc(2026, 6, 8),
    );
    container.read(inboxStateProvider.notifier).setRooms([_roomA(), roomB]);
    container
        .read(messageStoreProvider('roomB').notifier)
        .add(
          Msg(
            id: 'b1',
            from: 'kaitlyn',
            to: 'court',
            body: 'pick a restaurant?',
            ts: DateTime.utc(2026, 6, 9, 17, 5),
          ),
        );

    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          navigatorKey: navKey,
          home: const Scaffold(),
        ),
      ),
    );
    // Push the conversation so the back button (and thus its badge) exists.
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          room: _roomA(),
          selfUsername: 'court',
          onSend: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final badge = find.byKey(const Key('back-unread-badge'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('1')),
      findsOneWidget,
    );
  });

  testWidgets('typing re-asserts true on a heartbeat, then stops when idle', (
    tester,
  ) async {
    final events = <bool>[];
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        httpClientProvider.overrideWithValue(http.Client()),
        readStateStoreProvider.overrideWithValue(_readStateStore),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _roomA(),
            selfUsername: 'court',
            onSend: (_, _) {},
            onTyping: events.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Leading edge: first keystroke emits a single `true`.
    await tester.enterText(find.byKey(const Key('composer')), 'h');
    await tester.pump();
    expect(events, [true]);

    // Heartbeat (~3s) re-asserts `true` while still composing — this is the
    // fix: without it the partner's bubble would expire mid-typing.
    await tester.pump(const Duration(seconds: 3));
    expect(events, [true, true]);

    // No further keystrokes: the 4s idle timer fires `false` and cancels the
    // heartbeat (so no more events accumulate afterwards).
    await tester.pump(const Duration(seconds: 2));
    expect(events, [true, true, false]);
    await tester.pump(const Duration(seconds: 4));
    expect(events, [true, true, false], reason: 'heartbeat stopped after idle');
  });
}
