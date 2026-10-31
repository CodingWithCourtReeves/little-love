import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/chat_info_chrome.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_search_page.dart';
import 'package:littlelove/conversation/search_results.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/profile/profile_store.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/widget_waits.dart';

/// WCAG contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

final _room = Room(
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
  createdAt: DateTime.utc(2026),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete. In-process queries resolve on microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  Future<void> add(MessageDb db, String id, String from, DateTime local) =>
      db.upsert(
        Msg(id: id, from: from, to: 'r1', body: 'cake $id', ts: local.toUtc()),
        roomId: 'r1',
      );

  /// The search page as the app shows it, optionally with the device in
  /// 24-hour time. The override goes through [MaterialApp.builder]: the test
  /// platform's value doesn't reach the root MediaQuery the page reads.
  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    MessageDb db, {
    bool use24h = false,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [messageDbProvider.overrideWith((_) async => db)],
    );
    addTearDown(c.dispose);
    c
        .read(profileStoreProvider)
        .apply(
          PartnerProfile(
            username: 'kaitlyn',
            displayName: 'Kat',
            avatar: null,
            updatedAt: DateTime.utc(2026),
          ),
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(alwaysUse24HourFormat: use24h),
            child: child!,
          ),
          home: MessageSearchPage(room: _room, selfUsername: 'me'),
        ),
      ),
    );
    return c;
  }

  double topOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets('search results are newest first, grouped by day, with names '
      'and times', (tester) async {
    final db = await freshDb();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 13, 5);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 9, 30);
    final older = DateTime(2025, 3, 4, 18, 45);
    // Inserted out of order, so the list order can only come from the query.
    await add(db, 'm-old', 'kaitlyn', older);
    await add(db, 'm-today-me', 'me', today);
    await add(db, 'm-yesterday', 'kaitlyn', yesterday);
    await add(
      db,
      'm-today-kat',
      'kaitlyn',
      today.subtract(const Duration(minutes: 5)),
    );

    await pumpPage(tester, db, use24h: true);
    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'cake',
    );
    final rows = [
      'm-today-me',
      'm-today-kat',
      'm-yesterday',
      'm-old',
    ].map((id) => find.byKey(Key('search-result-$id'))).toList();
    await pumpUntilFound(tester, rows.last);

    // Newest first, top to bottom.
    for (var i = 1; i < rows.length; i++) {
      expect(topOf(tester, rows[i]), greaterThan(topOf(tester, rows[i - 1])));
    }
    // One day caption per group, each above its own rows.
    final captions = ['Today', 'Yesterday', 'Mar 4, 2025'];
    for (final c in captions) {
      expect(find.text(c), findsOneWidget, reason: c);
    }
    expect(topOf(tester, find.text('Today')), lessThan(topOf(tester, rows[0])));
    expect(
      topOf(tester, find.text('Yesterday')),
      greaterThan(topOf(tester, rows[1])),
    );
    expect(
      topOf(tester, find.text('Yesterday')),
      lessThan(topOf(tester, rows[2])),
    );
    expect(
      topOf(tester, find.text('Mar 4, 2025')),
      lessThan(topOf(tester, rows[3])),
    );
    // Display names, "You" for mine, and the device's 24-hour clock.
    expect(
      find.descendant(of: rows[0], matching: find.text('You')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rows[1], matching: find.text('Kat')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rows[0], matching: find.text('13:05')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rows[3], matching: find.text('18:45')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('search-scope-note')), findsOneWidget);
    expect(find.text(searchScopeNote), findsOneWidget);
  });

  testWidgets('result times follow the 12-hour clock when the device uses it', (
    tester,
  ) async {
    final db = await freshDb();
    await add(db, 'm1', 'kaitlyn', DateTime(2025, 3, 4, 18, 45));
    await pumpPage(tester, db);
    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'cake',
    );
    await pumpUntilFound(tester, find.byKey(const Key('search-result-m1')));
    expect(find.text('6:45 PM'), findsOneWidget);
  });

  testWidgets('the match is highlighted with the search tint, not bold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: const Scaffold(
          body: SnippetText(snippetHtml: 'a <b>cake</b> for you'),
        ),
      ),
    );
    final rich = tester.widget<RichText>(find.byType(RichText)).text;
    final spans = <TextSpan>[];
    rich.visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    final match = spans.singleWhere((s) => s.text == 'cake');
    expect(match.style?.backgroundColor, AppPalette.light.searchMatch);
    expect(match.style?.fontWeight, isNot(FontWeight.w700));
    final plain = spans.singleWhere((s) => s.text == 'a ');
    expect(plain.style?.backgroundColor, isNull);
  });

  testWidgets('tapping a result pops its message id', (tester) async {
    final db = await freshDb();
    await add(db, 'm1', 'kaitlyn', DateTime(2025, 3, 4, 18, 45));
    final c = ProviderContainer(
      overrides: [messageDbProvider.overrideWith((_) async => db)],
    );
    addTearDown(c.dispose);
    String? popped;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => popped = await Navigator.of(
                context,
              ).push(MessageSearchPage.route(room: _room, selfUsername: 'me')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'cake',
    );
    final row = find.byKey(const Key('search-result-m1'));
    await pumpUntilFound(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(popped, 'm1');
  });

  group('filter chips (#95)', () {
    Future<void> search(WidgetTester tester, String q) async {
      await tester.enterText(find.byKey(const Key('message-search-field')), q);
    }

    Finder row(String id) => find.byKey(Key('search-result-$id'));

    testWidgets('the sender chips filter the results by who sent them', (
      tester,
    ) async {
      final db = await freshDb();
      await add(db, 'm-kat', 'kaitlyn', DateTime(2025, 3, 4, 9));
      await add(db, 'm-me', 'me', DateTime(2025, 3, 4, 10));
      await pumpPage(tester, db);
      await search(tester, 'cake');
      await pumpUntilFound(tester, row('m-kat'));
      expect(row('m-me'), findsOneWidget);

      // Named for the partner.
      expect(find.text('From Kat'), findsOneWidget);
      // Each filter is a fresh query (a spinner shows both rows gone), so wait
      // for the row that stays, then check the other is filtered out.
      await tester.tap(find.byKey(const Key('search-chip-partner')));
      await tester.pump();
      await pumpUntilFound(tester, row('m-kat'));
      expect(row('m-me'), findsNothing);

      await tester.tap(find.byKey(const Key('search-chip-me')));
      await tester.pump();
      await pumpUntilFound(tester, row('m-me'));
      expect(row('m-kat'), findsNothing);

      await tester.tap(find.byKey(const Key('search-chip-all')));
      await pumpUntilFound(tester, row('m-kat'));
      expect(row('m-me'), findsOneWidget);
    });

    testWidgets('the Photos and Links chips open the gallery on that tab', (
      tester,
    ) async {
      final db = await freshDb();
      await pumpPage(tester, db);
      await tester.pump();

      await tester.tap(find.byKey(const Key('search-chip-photos')));
      await tester.pumpAndSettle();
      expect(find.text('No photos or videos yet'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-info-back')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('search-chip-links')));
      await tester.pumpAndSettle();
      expect(find.text('No links yet'), findsOneWidget);
    });

    testWidgets('every chip is at least 44pt tall to tap', (tester) async {
      final db = await freshDb();
      await pumpPage(tester, db);
      await tester.pump();
      for (final key in ['all', 'partner', 'me', 'photos', 'links']) {
        final size = tester.getSize(find.byKey(Key('search-chip-$key')));
        expect(size.height, greaterThanOrEqualTo(44), reason: key);
      }
    });
  });

  test(
    'snippets and their highlight pass 4.5:1 on the results card, and '
    'Cancel on its pill and the scope note on the veil, on every wallpaper',
    () {
      for (final wallpaper in WallpaperGradient.values) {
        final p = AppPalette.of(wallpaper.brightness);
        for (final spot in [...wallpaper.colors, wallpaper.base]) {
          for (final ground in [
            spot,
            Color.alphaBlend(wallpaper.doodleInk, spot),
          ]) {
            final veil = Color.alphaBlend(
              p.bgCanvas.withValues(alpha: veilAlpha),
              ground,
            );
            final card = Color.alphaBlend(infoCardColor(p), veil);
            final tint = Color.alphaBlend(p.searchMatch, card);
            final reason = '${wallpaper.label} at $ground';
            expect(
              _contrast(p.separatorText, card),
              greaterThanOrEqualTo(4.5),
              reason: 'snippet, $reason',
            );
            expect(
              _contrast(p.separatorText, tint),
              greaterThanOrEqualTo(4.5),
              reason: 'highlighted match, $reason',
            );
            expect(
              _contrast(p.accentUser, card),
              greaterThanOrEqualTo(4.5),
              reason: 'Cancel on its pill, $reason',
            );
            expect(
              _contrast(p.separatorText, veil),
              greaterThanOrEqualTo(4.5),
              reason: 'scope note, $reason',
            );
            expect(
              _contrast(p.textPrimary, card),
              greaterThanOrEqualTo(4.5),
              reason: 'chip label, $reason',
            );
          }
        }
      }
    },
  );
}
