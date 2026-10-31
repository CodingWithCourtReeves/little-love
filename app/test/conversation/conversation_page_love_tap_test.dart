import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/reaction_burst.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Room _room() => Room(
  roomId: 'roomA',
  name: '',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'AAA', x25519PubBase64: 'BBB'),
    Member(
      username: 'kaitlyn',
      ed25519PubBase64: 'CCC',
      x25519PubBase64: 'DDD',
    ),
  ],
  createdAt: DateTime.utc(2026, 10, 30),
);

final _account = LocalAccount(
  username: 'court',
  ed25519PubBase64: 'AAA',
  x25519PubBase64: 'BBB',
  createdAt: DateTime.utc(2026, 10, 30),
);

final _readStateStore = ReadStateStore(
  homeDirectory: Directory.systemTemp.createTempSync('conv_love_tap_rs'),
);

Msg _msg(
  String id,
  String from,
  String body, {
  int minute = 0,
  Map<String, String> reactions = const {},
}) => Msg(
  id: id,
  from: from,
  to: 'roomA',
  body: body,
  ts: DateTime.utc(2026, 10, 30, 18, minute),
  reactions: reactions,
);

ProviderContainer _container({MessageDb? db}) {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith((_) async => _account),
      httpClientProvider.overrideWithValue(http.Client()),
      readStateStoreProvider.overrideWithValue(_readStateStore),
      if (db != null) messageDbProvider.overrideWith((_) async => db),
    ],
  );
  container.read(inboxStateProvider.notifier).setRooms([_room()]);
  return container;
}

/// Records every haptic the page asks the platform for.
List<String?> _recordHaptics(WidgetTester tester) {
  final calls = <String?>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      calls.add(call.arguments as String?);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  void Function(String text)? onSend,
  void Function(String targetId, String emoji)? onReact,
  void Function(String clientMsgId)? onRetry,
  String? focusMessageId,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: ConversationPage(
          room: _room(),
          selfUsername: 'court',
          onSend: (text, _) => onSend?.call(text),
          onReact: onReact ?? (_, _) {},
          onRetry: onRetry,
          focusMessageId: focusMessageId,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _heart = find.byKey(const Key('composer-love-tap'));

/// The flying emoji of a playing burst (they live in the Overlay).
final _particles = find.byKey(const Key('reaction-burst-particles'));

/// Build the change, then one more frame: a burst inserts its particles into
/// the Overlay after the frame that built it.
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: under testWidgets' fake-async clock, isolate-backed
    // queries never complete. In-process queries resolve on microtasks.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  group('history loaded by a search jump', () {
    testWidgets('neither pops in nor bursts an old love tap', (tester) async {
      final raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: MessageDb.schemaVersion,
          onCreate: MessageDb.onCreate,
          onUpgrade: MessageDb.onUpgrade,
        ),
      );
      addTearDown(raw.close);
      final db = MessageDb.test(raw);
      final oldHeart = _msg('old-heart', 'kaitlyn', '❤️');
      final oldTarget = _msg('old-1', 'kaitlyn', 'the search hit', minute: 1);
      final recent = _msg('new-1', 'kaitlyn', 'recent', minute: 30);
      for (final m in [oldHeart, oldTarget, recent]) {
        await db.upsert(m, roomId: 'roomA');
      }
      final container = _container(db: db);
      addTearDown(container.dispose);
      // Only the recent window is in memory; the hit predates it, so the jump
      // loads the full history from the db.
      container.read(messageStoreProvider('roomA').notifier).setAll([recent]);

      await _pump(tester, container, focusMessageId: 'old-1');

      expect(find.text('the search hit'), findsOneWidget);
      expect(find.byKey(const Key('popin-old-heart')), findsNothing);
      expect(find.byType(ReactionBurst), findsNothing);
      // Let the jump's highlight pulse clear its timer.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('keeps hidden (unsupported) rows out of the timeline', (
      tester,
    ) async {
      final raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: MessageDb.schemaVersion,
          onCreate: MessageDb.onCreate,
          onUpgrade: MessageDb.onUpgrade,
        ),
      );
      addTearDown(raw.close);
      final db = MessageDb.test(raw);
      final hidden = _msg(
        'old-hidden',
        'kaitlyn',
        '',
        minute: 2,
      ).copyWith(unsupportedBody: '{"kind":"future"}');
      final oldTarget = _msg('old-1', 'kaitlyn', 'the search hit', minute: 1);
      final recent = _msg('new-1', 'kaitlyn', 'recent', minute: 30);
      for (final m in [hidden, oldTarget, recent]) {
        await db.upsert(m, roomId: 'roomA');
      }
      final container = _container(db: db);
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([recent]);

      await _pump(tester, container, focusMessageId: 'old-1');

      expect(find.text('the search hit'), findsOneWidget);
      expect(
        container.read(messageStoreProvider('roomA')).where((m) => m.isHidden),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('composer heart (#76)', () {
    testWidgets('shows only while the composer is empty', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(_heart, findsOneWidget);
      await tester.enterText(find.byKey(const Key('composer')), 'hey');
      await tester.pump();
      expect(_heart, findsNothing);
      await tester.enterText(find.byKey(const Key('composer')), '  ');
      await tester.pump();
      expect(_heart, findsOneWidget);
    });

    testWidgets('a tap sends a love tap with the heartbeat haptic', (
      tester,
    ) async {
      final haptics = _recordHaptics(tester);
      final container = _container();
      addTearDown(container.dispose);
      final sent = <String>[];
      await _pump(tester, container, onSend: sent.add);

      await tester.tap(_heart);
      await tester.pump(const Duration(milliseconds: 200));

      expect(sent, ['❤️']);
      expect(haptics, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.lightImpact',
      ]);
    });
  });

  group('love tap burst (#76)', () {
    testWidgets('a love tap that arrives bursts hearts once', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('roomA').notifier);
      store.setAll([_msg('1', 'kaitlyn', 'hi')]);
      await _pump(tester, container);

      store.add(_msg('2', 'kaitlyn', '❤️', minute: 1));
      await _pumpFrames(tester);
      expect(_particles, findsOneWidget);

      await tester.pumpAndSettle();
      expect(_particles, findsNothing);

      // Rebuilding the row (another message lands) must not replay it.
      store.add(_msg('3', 'kaitlyn', 'night', minute: 2));
      await _pumpFrames(tester);
      expect(_particles, findsNothing);
    });

    testWidgets(
      'my love tap burst survives the optimistic to server-id reconcile',
      (tester) async {
        final container = _container();
        addTearDown(container.dispose);
        final store = container.read(messageStoreProvider('roomA').notifier);
        store.setAll([_msg('1', 'kaitlyn', 'hi')]);
        await _pump(tester, container);

        // My optimistic love tap, keyed by its clientMsgId.
        store.add(
          Msg(
            id: 'cmid-1',
            clientMsgId: 'cmid-1',
            from: 'court',
            to: 'roomA',
            body: '❤️',
            ts: DateTime.utc(2026, 10, 30, 18, 1),
            sendStatus: SendStatus.sending,
          ),
        );
        await _pumpFrames(tester);
        final before = tester.state(find.byType(ReactionBurst));
        await tester.pump(const Duration(milliseconds: 200));

        // The self-copy echo swaps in the server id mid-burst.
        store.reconcile(
          'cmid-1',
          Msg(
            id: 'srv-1',
            clientMsgId: 'cmid-1',
            from: 'court',
            to: 'roomA',
            body: '❤️',
            ts: DateTime.utc(2026, 10, 30, 18, 1),
          ),
        );
        await _pumpFrames(tester);

        // Same burst, still flying: not restarted from zero, not cut off.
        expect(tester.state(find.byType(ReactionBurst)), same(before));
        expect(_particles, findsOneWidget);
        await tester.pumpAndSettle();
        expect(_particles, findsNothing);
      },
    );

    testWidgets('a love tap already in history does not burst on open', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg('1', 'kaitlyn', '❤️'),
      ]);
      await _pump(tester, container);
      expect(find.byType(ReactionBurst), findsNothing);
    });

    testWidgets('a heart inside other text is not a love tap', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('roomA').notifier);
      store.setAll([_msg('1', 'kaitlyn', 'hi')]);
      await _pump(tester, container);

      store.add(_msg('2', 'kaitlyn', 'love you ❤️', minute: 1));
      await tester.pump();
      expect(find.byType(ReactionBurst), findsNothing);
    });
  });

  group('reaction burst (#77)', () {
    testWidgets('a reaction that lands while the room is open bursts once', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('roomA').notifier);
      store.setAll([_msg('1', 'court', 'home in 20')]);
      await _pump(tester, container);

      store.applyReaction('1', 'kaitlyn', '😂');
      await _pumpFrames(tester);
      expect(_particles, findsOneWidget);

      await tester.pumpAndSettle();
      expect(_particles, findsNothing);

      // Rebuilding the row (another message lands) must not replay it.
      store.add(_msg('2', 'kaitlyn', 'ok', minute: 1));
      await _pumpFrames(tester);
      expect(_particles, findsNothing);
    });

    testWidgets('reactions already in history do not burst on open', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg('1', 'court', 'home in 20', reactions: const {'kaitlyn': '❤️'}),
      ]);
      await _pump(tester, container);
      expect(find.byType(ReactionBurst), findsNothing);
    });

    testWidgets('taking a reaction back does not burst', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('roomA').notifier);
      store.setAll([
        _msg(
          '1',
          'court',
          'home in 20',
          reactions: const {'kaitlyn': '❤️', 'court': '😂'},
        ),
      ]);
      await _pump(tester, container);

      store.applyReaction('1', 'kaitlyn', '');
      await tester.pump();
      expect(find.byType(ReactionBurst), findsNothing);
    });

    testWidgets('Reduce Motion: no bursts at all', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      final store = container.read(messageStoreProvider('roomA').notifier);
      store.setAll([_msg('1', 'court', 'home in 20')]);
      await _pump(tester, container, reduceMotion: true);

      store.applyReaction('1', 'kaitlyn', '😂');
      store.add(_msg('2', 'kaitlyn', '❤️', minute: 1));
      await tester.pump();
      expect(find.byType(ReactionBurst), findsNothing);
    });
  });

  group('reaction haptics (#77)', () {
    testWidgets(
      'double-tap to heart taps lightly; tapping my badge back clicks',
      (tester) async {
        final haptics = _recordHaptics(tester);
        final container = _container();
        addTearDown(container.dispose);
        final store = container.read(messageStoreProvider('roomA').notifier);
        store.setAll([_msg('1', 'kaitlyn', 'home in 20')]);
        final reacted = <String>[];
        await _pump(
          tester,
          container,
          onReact: (id, emoji) {
            reacted.add(emoji);
            store.applyReaction(id, 'court', emoji);
          },
        );

        final bubble = find.text('home in 20');
        await tester.tap(bubble);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(bubble);
        await tester.pumpAndSettle();
        expect(reacted, ['❤️']);
        expect(haptics, ['HapticFeedbackType.lightImpact']);

        // My badge, tapped, takes the heart back with a softer click.
        await tester.tap(_badge('1'));
        await tester.pumpAndSettle();
        expect(reacted, ['❤️', '']);
        expect(haptics, [
          'HapticFeedbackType.lightImpact',
          'HapticFeedbackType.selectionClick',
        ]);
      },
    );
  });

  group('reaction badge (#79)', () {
    testWidgets('no badge until someone reacts', (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg('1', 'kaitlyn', 'home in 20'),
      ]);
      await _pump(tester, container);
      expect(_badge('1'), findsNothing);
    });

    testWidgets(
      "sits on the partner bubble's top-right corner, overlapping it",
      (tester) async {
        final container = _container();
        addTearDown(container.dispose);
        container.read(messageStoreProvider('roomA').notifier).setAll([
          _msg('1', 'kaitlyn', 'home in 20', reactions: const {'court': '❤️'}),
        ]);
        await _pump(tester, container);

        final bubble = tester.getRect(find.byKey(const Key('bubble-bg-1')));
        final badge = tester.getRect(_badge('1'));
        // Straddles the top edge and the right edge (toward the middle).
        expect(badge.top, lessThan(bubble.top));
        expect(badge.bottom, greaterThan(bubble.top));
        expect(badge.left, lessThan(bubble.right));
        expect(badge.right, greaterThan(bubble.right));
      },
    );

    testWidgets("sits on my bubble's top-left corner, overlapping it", (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg('1', 'court', 'home in 20', reactions: const {'kaitlyn': '😂'}),
      ]);
      await _pump(tester, container);

      final bubble = tester.getRect(find.byKey(const Key('bubble-bg-1')));
      final badge = tester.getRect(_badge('1'));
      expect(badge.top, lessThan(bubble.top));
      expect(badge.bottom, greaterThan(bubble.top));
      expect(badge.left, lessThan(bubble.left));
      expect(badge.right, greaterThan(bubble.left));
    });

    testWidgets("sits on a big emoji's top-right corner", (tester) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg('1', 'kaitlyn', '😂', reactions: const {'court': '❤️'}),
      ]);
      await _pump(tester, container);

      final glyph = tester.getRect(find.text('😂'));
      final badge = tester.getRect(_badge('1'));
      expect(badge.bottom, greaterThan(glyph.top));
      expect(badge.top, lessThan(glyph.top));
      expect(badge.left, lessThan(glyph.right));
      expect(badge.center.dx, greaterThan(glyph.center.dx));
    });

    testWidgets('a failed send with a reaction still retries on tap', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        Msg(
          id: 'cmid-9',
          clientMsgId: 'cmid-9',
          from: 'court',
          to: 'roomA',
          body: 'did this send',
          ts: DateTime.utc(2026, 10, 30, 18),
          sendStatus: SendStatus.failed,
          reactions: const {'kaitlyn': '😂'},
        ),
      ]);
      final retried = <String>[];
      await _pump(tester, container, onRetry: retried.add);

      expect(_badge('cmid-9'), findsOneWidget);
      await tester.tap(find.text('did this send'));
      // With reactions on, the bubble's double-tap detector holds a single tap
      // for its 300ms window before the retry tap wins (as before this badge).
      await tester.pump(const Duration(milliseconds: 350));
      expect(retried, ['cmid-9']);
    });

    testWidgets('shows both reactions in one badge, the partner first', (
      tester,
    ) async {
      final container = _container();
      addTearDown(container.dispose);
      container.read(messageStoreProvider('roomA').notifier).setAll([
        _msg(
          '1',
          'kaitlyn',
          'home in 20',
          reactions: const {'court': '❤️', 'kaitlyn': '😂'},
        ),
      ]);
      await _pump(tester, container);

      final texts = tester
          .widgetList<Text>(
            find.descendant(of: _badge('1'), matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .toList();
      expect(texts, ['😂', '❤️']);
    });

    testWidgets(
      "tapping the partner's badge matches their reaction, without the double-tap wait",
      (tester) async {
        final container = _container();
        addTearDown(container.dispose);
        container.read(messageStoreProvider('roomA').notifier).setAll([
          _msg('1', 'court', 'home in 20', reactions: const {'kaitlyn': '😂'}),
        ]);
        final reacted = <String>[];
        await _pump(tester, container, onReact: (_, e) => reacted.add(e));

        await tester.tap(_badge('1'));
        // One frame, well inside the 300ms double-tap timeout: the badge is
        // outside the bubble's double-tap detector, so the tap lands at once.
        await tester.pump();
        expect(reacted, ['😂']);
      },
    );
  });
}

Finder _badge(String id) => find.byKey(Key('reaction-badge-$id'));
