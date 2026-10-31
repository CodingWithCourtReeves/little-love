import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/composer_draft.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_search.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/reply_ref.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_read_state.dart';
import '../support/widget_waits.dart';

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

/// An older match from the partner, a screenful of other messages, then a
/// newer match of mine near the bottom. Ids avoid the page's const keys.
List<Msg> _history() {
  final t0 = DateTime.utc(2026, 6, 13, 18);
  Msg msg(String id, String from, String body, int minute) => Msg(
    id: id,
    from: from,
    to: 'r1',
    body: body,
    ts: t0.add(Duration(minutes: minute)),
  );
  return [
    msg('srv-old', 'kaitlyn', 'Strawberries please', 0),
    for (var i = 1; i <= 30; i++)
      msg('srv-filler-$i', i.isEven ? 'me' : 'kaitlyn', 'line number $i', i),
    msg('srv-new', 'me', 'Strawberry shortcake this weekend?', 31),
    msg('srv-tail', 'kaitlyn', 'Yes please', 32),
  ];
}

/// The real DB, except each search waits until the test releases it, so a
/// test can make a search finish late or out of order.
class _GatedSearchDb extends SqliteMessageDb {
  _GatedSearchDb(super.db);

  final pending = <Completer<void>>[];

  @override
  Future<List<SearchHit>> search(
    String query, {
    String? roomId,
    String? from,
    int limit = 50,
    SearchOrder order = SearchOrder.relevance,
  }) async {
    final gate = Completer<void>();
    pending.add(gate);
    await gate.future;
    return super.search(
      query,
      roomId: roomId,
      from: from,
      limit: limit,
      order: order,
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete. In-process queries resolve on microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Database> openDb() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<MessageDb> seed(MessageDb mdb, List<Msg> extra) async {
    for (final m in [..._history(), ...extra]) {
      await mdb.upsert(m, roomId: 'r1');
    }
    return mdb;
  }

  Future<MessageDb> seededDb({List<Msg> extra = const []}) async =>
      seed(MessageDb.test(await openDb()), extra);

  /// The chat as the app shows it: pushed over a home route (so back has
  /// somewhere to go), its history in both the store and the DB.
  Future<ProviderContainer> openRoom(
    WidgetTester tester,
    MessageDb db, {
    List<Msg> extra = const [],
  }) async {
    final c = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
        messageDbProvider.overrideWith((_) async => db),
        connectionUpProvider.overrideWithValue(true),
      ],
    );
    addTearDown(c.dispose);
    c.read(messageStoreProvider('r1').notifier).setAll([
      ..._history(),
      ...extra,
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConversationPage(
                    room: _room(),
                    selfUsername: 'me',
                    onSend: (_, _) {},
                    onReact: (_, _) {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return c;
  }

  /// Title pill → chat info → Search, as a user gets there.
  Future<void> enterSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('room-title-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-info-search')));
    await tester.pumpAndSettle();
  }

  String counter(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('search-counter'))).data ?? '';

  Future<void> search(WidgetTester tester, String q, String expect) async {
    await tester.enterText(find.byKey(const Key('chat-search-field')), q);
    await pumpUntilTrue(tester, () => counter(tester) == expect);
  }

  /// The bubble text containing [snippet].
  Finder bubbleText(String snippet) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(snippet),
  );

  /// The background behind [word] in the bubble containing [snippet], or null
  /// if that word isn't marked.
  Color? markBehind(WidgetTester tester, String snippet, String word) {
    final text = tester.widget<RichText>(bubbleText(snippet).first).text;
    Color? found;
    text.visitChildren((s) {
      if (s is TextSpan && (s.text ?? '').contains(word)) {
        found = s.style?.backgroundColor;
        return false;
      }
      return true;
    });
    return found;
  }

  bool onScreen(WidgetTester tester, Finder f) {
    if (f.evaluate().isEmpty) return false;
    final r = tester.getRect(f.first);
    final screen = Offset.zero & tester.view.physicalSize;
    return screen.contains(r.center);
  }

  /// Lets the jump-to-match highlight pulse run out, so no timer is left
  /// pending when the test ends.
  Future<void> letPulseFinish(WidgetTester tester) async {
    await tester.pumpAndSettle(); // the scroll to the match
    await tester.pump(const Duration(seconds: 2)); // then the pulse's delay
  }

  bool searchFieldFocused(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('chat-search-field')),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode
      .hasFocus;

  testWidgets('the Search tile drops back into the chat in search mode', (
    tester,
  ) async {
    final db = await seededDb();
    await openRoom(tester, db);
    expect(find.byKey(const Key('composer')), findsOneWidget);

    await enterSearch(tester);
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(find.byKey(const Key('chat-search-field')), findsOneWidget);
    expect(find.byKey(const Key('search-match-bar')), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(find.byKey(const Key('room-title-pill')), findsNothing);
    expect(searchFieldFocused(tester), isTrue);
  });

  testWidgets('matches are marked in their bubbles, the newest first and '
      'strongest', (tester) async {
    final db = await seededDb();
    await openRoom(tester, db);
    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 2');

    final p = AppPalette.light;
    expect(markBehind(tester, 'shortcake', 'Strawberry'), p.searchMatchCurrent);
    // The word, not the whole message.
    expect(markBehind(tester, 'shortcake', 'shortcake'), isNull);
    // A message that doesn't match isn't marked.
    expect(markBehind(tester, 'Yes please', 'please'), isNull);
    await letPulseFinish(tester);
  });

  testWidgets('stepping to an older match scrolls it into view and marks it '
      'current', (tester) async {
    final db = await seededDb();
    await openRoom(tester, db);
    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 2');
    // The older match starts out of view, far up the history.
    expect(onScreen(tester, bubbleText('Strawberries please')), isFalse);

    await tester.tap(find.byKey(const Key('search-older')));
    await pumpUntilTrue(
      tester,
      () => onScreen(tester, bubbleText('Strawberries please')),
    );
    expect(counter(tester), '2 of 2');
    final p = AppPalette.light;
    expect(
      markBehind(tester, 'Strawberries please', 'Strawberries'),
      p.searchMatchCurrent,
    );
    // The keyboard drops so the matches stay visible.
    expect(searchFieldFocused(tester), isFalse);
    // At the oldest match the older arrow is disabled; newer steps back.
    expect(
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byKey(const Key('search-older')),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('search-newer')));
    await pumpUntilTrue(tester, () => counter(tester) == '1 of 2');
    await pumpUntilTrue(
      tester,
      () => onScreen(tester, bubbleText('shortcake')),
    );
    await letPulseFinish(tester);
    expect(markBehind(tester, 'shortcake', 'Strawberry'), p.searchMatchCurrent);
  });

  testWidgets('cancelling search restores the draft and the pending reply', (
    tester,
  ) async {
    final db = await seededDb();
    await db.saveDraft(
      'r1',
      const ComposerDraft(
        text: '',
        replyTo: ReplyRef(
          id: 'srv-tail',
          author: 'kaitlyn',
          kind: 'text',
          text: 'Yes please',
        ),
      ),
    );
    await openRoom(tester, db);
    await tester.enterText(find.byKey(const Key('composer')), 'half a thought');
    await tester.pump();
    expect(find.byKey(const Key('reply-banner')), findsOneWidget);

    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 2');
    await tester.tap(find.byKey(const Key('chat-search-cancel')));
    await tester.pumpAndSettle();

    await letPulseFinish(tester);
    expect(find.byKey(const Key('search-match-bar')), findsNothing);
    expect(find.byKey(const Key('chat-search-field')), findsNothing);
    final composer = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('composer')),
        matching: find.byType(EditableText),
      ),
    );
    expect(composer.controller.text, 'half a thought');
    expect(find.byKey(const Key('reply-banner')), findsOneWidget);
    // The marks are gone with it.
    expect(markBehind(tester, 'shortcake', 'Strawberry'), isNull);
    // And the saved draft still holds the reply.
    await tester.pump(const Duration(seconds: 2));
    expect((await db.draftFor('r1'))?.replyTo?.id, 'srv-tail');
  });

  testWidgets('List opens the results, and tapping a row comes back to search '
      'mode at that match', (tester) async {
    final db = await seededDb();
    await openRoom(tester, db);
    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 2');

    await tester.tap(find.byKey(const Key('search-list')));
    final oldRow = find.byKey(const Key('search-result-srv-old'));
    await pumpUntilFound(tester, oldRow);
    // The list arrives with the chat's query.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-search-field')))
          .controller
          ?.text,
      'strawberr',
    );
    await tester.tap(oldRow);
    // Until the list's route is gone, its own snippet would match the finder.
    await pumpUntilTrue(
      tester,
      () => find.byKey(const Key('search-results')).evaluate().isEmpty,
    );
    await pumpUntilTrue(tester, () => counter(tester) == '2 of 2');
    await pumpUntilTrue(
      tester,
      () => onScreen(tester, bubbleText('Strawberries please')),
    );
    await letPulseFinish(tester);
    expect(
      markBehind(tester, 'Strawberries please', 'Strawberries'),
      AppPalette.light.searchMatchCurrent,
    );
  });

  testWidgets('back leaves search mode before it leaves the chat', (
    tester,
  ) async {
    final db = await seededDb();
    await openRoom(tester, db);
    await enterSearch(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ConversationPage), findsNothing);
  });

  testWidgets('the match bar arrows and List are at least 44pt', (
    tester,
  ) async {
    final db = await seededDb();
    await openRoom(tester, db);
    await enterSearch(tester);
    for (final key in ['search-older', 'search-newer', 'search-list']) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.height, greaterThanOrEqualTo(44), reason: key);
      expect(size.width, greaterThanOrEqualTo(44), reason: key);
    }
  });

  testWidgets('a hit found while its row was optimistic stays marked and '
      'reachable after the echo reconciles it', (tester) async {
    // My newest send, still optimistic: the store and the DB know it by its
    // clientMsgId until the server's echo swaps in the server id.
    final optimistic = Msg(
      id: 'cmid-jam',
      clientMsgId: 'cmid-jam',
      from: 'me',
      to: 'r1',
      body: 'strawberry jam too',
      ts: DateTime.utc(2026, 6, 13, 18, 40),
      sendStatus: SendStatus.sending,
    );
    final db = await seededDb(extra: [optimistic]);
    final c = await openRoom(tester, db, extra: [optimistic]);
    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 3');
    final p = AppPalette.light;
    expect(markBehind(tester, 'jam too', 'strawberry'), p.searchMatchCurrent);

    c
        .read(messageStoreProvider('r1').notifier)
        .reconcile(
          'cmid-jam',
          Msg(
            id: 'srv-jam',
            from: 'me',
            to: 'r1',
            body: 'strawberry jam too',
            ts: DateTime.utc(2026, 6, 13, 18, 40),
          ),
        );
    await tester.pump();
    expect(markBehind(tester, 'jam too', 'strawberry'), p.searchMatchCurrent);

    // Step away and back: the jump finds the row under its server id.
    await tester.tap(find.byKey(const Key('search-older')));
    await pumpUntilTrue(tester, () => counter(tester) == '2 of 3');
    await letPulseFinish(tester);
    await tester.tap(find.byKey(const Key('search-newer')));
    await pumpUntilTrue(tester, () => counter(tester) == '1 of 3');
    await letPulseFinish(tester);
    expect(markBehind(tester, 'jam too', 'strawberry'), p.searchMatchCurrent);
    expect(onScreen(tester, bubbleText('jam too')), isTrue);
  });

  testWidgets('a search that finishes after Cancel, or after a newer search, '
      'changes nothing', (tester) async {
    final db = _GatedSearchDb(await openDb());
    await seed(db, const []);
    await openRoom(tester, db);
    await enterSearch(tester);

    // Two searches in flight; the older one finishes last.
    await tester.enterText(
      find.byKey(const Key('chat-search-field')),
      'strawberr',
    );
    await pumpUntilTrue(tester, () => db.pending.length == 1);
    await tester.enterText(find.byKey(const Key('chat-search-field')), 'yes');
    await pumpUntilTrue(tester, () => db.pending.length == 2);
    db.pending[1].complete();
    await pumpUntilTrue(tester, () => counter(tester) == '1 of 1');
    db.pending[0].complete();
    await letPulseFinish(tester);
    expect(counter(tester), '1 of 1');
    expect(markBehind(tester, 'shortcake', 'Strawberry'), isNull);

    // One more in flight, then Cancel before it lands.
    await tester.enterText(
      find.byKey(const Key('chat-search-field')),
      'strawberr',
    );
    await pumpUntilTrue(tester, () => db.pending.length == 3);
    await tester.tap(find.byKey(const Key('chat-search-cancel')));
    await tester.pump();
    db.pending[2].complete();
    await letPulseFinish(tester);
    expect(find.byKey(const Key('search-match-bar')), findsNothing);
    expect(find.byKey(const Key('composer')), findsOneWidget);
    expect(markBehind(tester, 'shortcake', 'Strawberry'), isNull);
  });

  testWidgets('a match inside a link is marked and the link still opens', (
    tester,
  ) async {
    final link = Msg(
      id: 'srv-link',
      from: 'kaitlyn',
      to: 'r1',
      body: 'see www.strawberryfest.com tonight',
      ts: DateTime.utc(2026, 6, 13, 18, 50),
    );
    final db = await seededDb(extra: [link]);
    await openRoom(tester, db, extra: [link]);
    await enterSearch(tester);
    await search(tester, 'strawberr', '1 of 3');

    final text = tester.widget<RichText>(bubbleText('tonight').first).text;
    TextSpan? marked;
    text.visitChildren((s) {
      if (s is TextSpan && s.text == 'strawberryfest') marked = s;
      return marked == null;
    });
    expect(marked, isNotNull);
    expect(marked!.style?.backgroundColor, AppPalette.light.searchMatchCurrent);
    // Still part of the tappable link, and still underlined.
    expect(marked!.recognizer, isNotNull);
    expect(marked!.style?.decoration, TextDecoration.underline);
    await letPulseFinish(tester);
  });
}
