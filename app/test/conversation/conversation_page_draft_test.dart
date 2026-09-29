import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/staged_attachment.dart';
import 'package:littlelove/conversation/composer_draft.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/draft_autosave.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/reply_ref.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_read_state.dart';

Room _room() => Room(
  roomId: 'r1',
  name: 'Kaitlyn',
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

/// A staged video with no on-disk path renders a plain placeholder chip, so
/// the test never decodes fake image bytes.
StagedAttachment _video(String name) => StagedAttachment(
  bytes: Uint8List.fromList([0, 1, 2]),
  filename: name,
  mime: 'video/mp4',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete. In-process queries resolve on microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  Future<MessageDb> freshDb() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    return MessageDb.test(db);
  }

  ProviderContainer containerFor(MessageDb db) {
    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
        messageDbProvider.overrideWith((_) async => db),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> openRoom(
    WidgetTester tester,
    ProviderContainer c, {
    SendCallback? onSend,
    void Function(String id, String text)? onEdit,
    List<StagedAttachment> pick = const [],
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ConversationPage(
            room: _room(),
            selfUsername: 'me',
            onSend: onSend ?? (_, _) {},
            onReact: (_, _) {},
            onEdit: onEdit ?? (_, _) {},
            onPickMedia: () async => pick,
            onSendMedia: (_, _, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Leave the room: unmount the page but keep the provider container (the
  /// app session) alive, as popping back to the inbox does.
  Future<void> leaveRoom(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
  }

  String composerText(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('composer')),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  testWidgets('typed text is saved once typing pauses and restored on reopen', (
    tester,
  ) async {
    final db = await freshDb();
    final c = containerFor(db);
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'half a thought');
    await tester.pump(DraftAutosave.defaultDelay * 2);
    expect((await db.draftFor('r1'))!.text, 'half a thought');

    await leaveRoom(tester, c);
    await openRoom(tester, c);
    expect(composerText(tester), 'half a thought');
  });

  testWidgets('leaving the room mid-typing still saves the draft', (
    tester,
  ) async {
    final db = await freshDb();
    final c = containerFor(db);
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'quick exit');
    // No debounce wait: dispose must flush.
    await leaveRoom(tester, c);
    expect((await db.draftFor('r1'))!.text, 'quick exit');
  });

  testWidgets('backgrounding the app saves the draft right away', (
    tester,
  ) async {
    final db = await freshDb();
    final c = containerFor(db);
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'brb');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect((await db.draftFor('r1'))!.text, 'brb');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('sending clears the saved draft', (tester) async {
    final db = await freshDb();
    final c = containerFor(db);
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'sent now');
    await tester.pump(DraftAutosave.defaultDelay * 2);
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();

    expect(await db.draftFor('r1'), isNull);
    await leaveRoom(tester, c);
    await openRoom(tester, c);
    expect(composerText(tester), isEmpty);
  });

  testWidgets('a quoted reply is part of the draft and is restored', (
    tester,
  ) async {
    final db = await freshDb();
    await db.saveDraft(
      'r1',
      const ComposerDraft(
        text: 'yes!',
        replyTo: ReplyRef(
          id: 'srv-1',
          author: 'kaitlyn',
          kind: 'text',
          text: 'dinner at 7?',
        ),
      ),
    );
    final c = containerFor(db);
    await openRoom(tester, c);

    expect(composerText(tester), 'yes!');
    expect(find.byKey(const Key('reply-banner')), findsOneWidget);
    expect(find.text('dinner at 7?'), findsOneWidget);
  });

  testWidgets('cancelling the reply chip is saved too', (tester) async {
    final db = await freshDb();
    await db.saveDraft(
      'r1',
      const ComposerDraft(
        text: '',
        replyTo: ReplyRef(id: 'srv-1', author: 'kaitlyn', kind: 'text'),
      ),
    );
    final c = containerFor(db);
    await openRoom(tester, c);

    await tester.tap(find.byKey(const Key('reply-cancel')));
    await leaveRoom(tester, c);
    expect(await db.draftFor('r1'), isNull);
  });

  testWidgets('staged media survives leaving and reopening the room', (
    tester,
  ) async {
    final db = await freshDb();
    final c = containerFor(db);
    await openRoom(tester, c, pick: [_video('clip.mp4')]);

    await tester.tap(find.byKey(const Key('composer-attach')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('staging-tray')), findsOneWidget);

    await leaveRoom(tester, c);
    await openRoom(tester, c);
    expect(find.byKey(const Key('staging-tray')), findsOneWidget);
  });

  testWidgets('editing a message never overwrites the draft, and cancelling '
      'the edit brings the draft back', (tester) async {
    final db = await freshDb();
    final c = containerFor(db);
    c
        .read(messageStoreProvider('r1').notifier)
        .add(
          Msg(
            id: 'srv-1',
            from: 'me',
            to: 'r1',
            body: 'typo mesage',
            ts: DateTime.utc(2026, 6, 13, 10),
          ),
        );
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'my draft');
    await tester.longPress(find.text('typo mesage'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();
    expect(composerText(tester), 'typo mesage');

    // Typing in edit mode must not replace the saved draft.
    await tester.enterText(find.byKey(const Key('composer')), 'typo message');
    await tester.pump(DraftAutosave.defaultDelay * 2);
    expect((await db.draftFor('r1'))!.text, 'my draft');

    await tester.tap(find.byKey(const Key('edit-cancel')));
    await tester.pumpAndSettle();
    expect(composerText(tester), 'my draft');
  });

  Msg mine(String id, String body, int minute) => Msg(
    id: id,
    from: 'me',
    to: 'r1',
    body: body,
    ts: DateTime.utc(2026, 6, 13, 10, minute),
  );

  Future<void> startEditing(WidgetTester tester, String body) async {
    await tester.longPress(find.text(body));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();
  }

  testWidgets('switching to editing another message without finishing the '
      'first keeps the original draft', (tester) async {
    final db = await freshDb();
    final c = containerFor(db);
    final store = c.read(messageStoreProvider('r1').notifier);
    store.add(mine('srv-1', 'first msg', 0));
    store.add(mine('srv-2', 'second msg', 1));
    await openRoom(tester, c);

    await tester.enterText(find.byKey(const Key('composer')), 'my draft');
    await startEditing(tester, 'first msg');
    // The composer now shows "first msg"; long-press the other bubble.
    await startEditing(tester, 'second msg');
    await tester.pump(DraftAutosave.defaultDelay * 2);
    expect((await db.draftFor('r1'))!.text, 'my draft');

    await tester.tap(find.byKey(const Key('edit-cancel')));
    await tester.pumpAndSettle();
    expect(composerText(tester), 'my draft');
  });

  testWidgets('sending in edit mode commits the edit even with media staged, '
      'and keeps both the tray and the draft', (tester) async {
    final db = await freshDb();
    final c = containerFor(db);
    c.read(messageStoreProvider('r1').notifier).add(mine('srv-1', 'typo', 0));
    final edits = <(String, String)>[];
    await openRoom(
      tester,
      c,
      pick: [_video('clip.mp4')],
      onEdit: (id, text) => edits.add((id, text)),
    );

    await tester.enterText(find.byKey(const Key('composer')), 'my draft');
    await tester.tap(find.byKey(const Key('composer-attach')));
    await tester.pumpAndSettle();
    await startEditing(tester, 'typo');
    await tester.enterText(find.byKey(const Key('composer')), 'fixed');
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();

    expect(edits, [('srv-1', 'fixed')]);
    expect(find.byKey(const Key('edit-banner')), findsNothing);
    expect(find.byKey(const Key('staging-tray')), findsOneWidget);
    expect(composerText(tester), 'my draft');
    expect((await db.draftFor('r1'))!.text, 'my draft');
  });

  testWidgets('leaving before the saved draft has loaded does not delete it', (
    tester,
  ) async {
    final db = await freshDb();
    await db.saveDraft('r1', const ComposerDraft(text: 'keep me'));
    // A slow first SQLCipher open: the db resolves only after the page is gone.
    final slowDb = Completer<MessageDb>();
    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
        messageDbProvider.overrideWith((_) => slowDb.future),
      ],
    );
    addTearDown(c.dispose);
    await openRoom(tester, c);
    await leaveRoom(tester, c);

    slowDb.complete(db);
    await tester.pump();
    expect((await db.draftFor('r1'))!.text, 'keep me');
  });

  testWidgets('backgrounding before the saved draft has loaded does not '
      'delete it', (tester) async {
    final db = await freshDb();
    await db.saveDraft('r1', const ComposerDraft(text: 'keep me'));
    final slowDb = Completer<MessageDb>();
    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
        messageDbProvider.overrideWith((_) => slowDb.future),
      ],
    );
    addTearDown(c.dispose);
    await openRoom(tester, c);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    slowDb.complete(db);
    await tester.pump();
    expect((await db.draftFor('r1'))!.text, 'keep me');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // ...and it still restores into the composer once the load lands.
    expect(composerText(tester), 'keep me');
  });
}
