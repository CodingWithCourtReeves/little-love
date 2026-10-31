import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/bubble_background.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_content.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';

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

Future<ProviderContainer> _container(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith((_) async => _account),
      hermeticReadStateStore(),
      // Voice bubbles read the socket for downloads; never connect in tests.
      liveConnectionProvider.overrideWith(
        (_) => Completer<LiveConnection>().future,
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(accountProvider.future);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  AppPalette palette = AppPalette.light,
  RetryCallback? onRetry,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(palette),
        home: ConversationPage(
          room: _room(),
          selfUsername: 'me',
          onSend: (_, _) {},
          onReact: (_, _) {},
          onRetry: onRetry,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// A text message at [h]:[m] local on Jun 13 2026.
Msg _msg(
  String id,
  String from, {
  int h = 10,
  required int m,
  int day = 13,
  String? clientMsgId,
  SendStatus sendStatus = SendStatus.sent,
  Map<String, String> reactions = const {},
  String? callOutcome,
}) => Msg(
  id: id,
  from: from,
  to: 'r1',
  body: callOutcome == null ? 'body $id' : '📞 Call',
  ts: DateTime(2026, 6, day, h, m),
  clientMsgId: clientMsgId,
  sendStatus: sendStatus,
  reactions: reactions,
  callOutcome: callOutcome,
);

final _voice = AttachmentDescriptor(
  blobKey: 'voice-1',
  contentKeyB64: 'k',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: 'voice.m4a',
  size: 999,
  width: 0,
  height: 0,
  durationMs: 4200,
  thumbB64: '',
  waveform: List<int>.filled(64, 9),
);

/// A voice memo from [from] at 10:[m].
Msg _voiceMsg(String id, String from, {required int m}) => Msg(
  id: id,
  from: from,
  to: 'r1',
  body: '',
  ts: DateTime(2026, 6, 13, 10, m),
  attachment: _voice,
);

/// A rename line from [from] at 10:[m], optionally an optimistic own send.
Msg _channelLine(
  String id,
  String from, {
  required int m,
  String? clientMsgId,
  SendStatus sendStatus = SendStatus.sent,
}) => Msg(
  id: id,
  from: from,
  to: 'r1',
  body: '',
  ts: DateTime(2026, 6, 13, 10, m),
  clientMsgId: clientMsgId,
  sendStatus: sendStatus,
  channelUpdate: const ChannelUpdateContent(name: 'Us'),
);

BubbleBackground _painter(WidgetTester tester, String key) =>
    tester.widget<CustomPaint>(find.byKey(Key('bubble-bg-$key'))).painter!
        as BubbleBackground;

bool _tail(WidgetTester tester, String key) => _painter(tester, key).tail;

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(Key('bubble-bg-$key')));

void main() {
  testWidgets('only the last bubble of a run has a tail', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    for (final (i, id) in ['a', 'b', 'c'].indexed) {
      store.add(_msg(id, 'me', m: i));
    }
    store.add(_msg('d', 'kaitlyn', m: 3));
    store.add(_msg('e', 'kaitlyn', m: 4));

    await _pump(tester, container);
    expect(
      [for (final k in 'abcde'.split('')) _tail(tester, k)],
      [false, false, true, false, true],
    );
  });

  testWidgets('corners facing the rest of the run soften; the outer edge '
      'keeps its 15px', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    for (final (i, id) in ['a', 'b', 'c'].indexed) {
      store.add(_msg(id, 'me', m: i));
    }
    store.add(_msg('d', 'kaitlyn', m: 3));
    store.add(_msg('e', 'kaitlyn', m: 4));

    await _pump(tester, container);
    const outer = Radius.circular(15);
    const inner = Radius.circular(6);
    // Mine (tail side right): first softens bottom-right, middle both right
    // corners, last its top-right.
    expect(
      _painter(tester, 'a').radius,
      const BorderRadius.only(
        topLeft: outer,
        bottomLeft: outer,
        topRight: outer,
        bottomRight: inner,
      ),
    );
    expect(
      _painter(tester, 'b').radius,
      const BorderRadius.only(
        topLeft: outer,
        bottomLeft: outer,
        topRight: inner,
        bottomRight: inner,
      ),
    );
    expect(_painter(tester, 'c').radius.topRight, inner);
    // The partner's run mirrors it on the left.
    expect(_painter(tester, 'd').radius.bottomLeft, inner);
    expect(_painter(tester, 'd').radius.topLeft, outer);
    expect(_painter(tester, 'e').radius.topLeft, inner);
    expect(_painter(tester, 'e').radius.topRight, outer);
  });

  testWidgets('runs break at day and gap separators and at call logs', (
    tester,
  ) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    // y1 is yesterday, minutes before t1: only the day separator splits them.
    store.add(_msg('y1', 'me', day: 12, h: 23, m: 55));
    store.add(_msg('t1', 'me', h: 0, m: 1));
    store.add(_msg('t2', 'me', h: 0, m: 2));
    store.add(_msg('call', 'me', h: 0, m: 3, callOutcome: 'completed'));
    store.add(_msg('t3', 'me', h: 0, m: 4));
    // An hour's silence: a gap header splits t3 from g1.
    store.add(_msg('g1', 'me', h: 1, m: 30));

    await _pump(tester, container);
    expect(_tail(tester, 'y1'), isTrue, reason: 'ends before the day break');
    expect(_tail(tester, 't1'), isFalse);
    expect(_tail(tester, 't2'), isTrue, reason: 'ends before the call log');
    expect(_tail(tester, 't3'), isTrue, reason: 'ends before the gap header');
    expect(_tail(tester, 'g1'), isTrue);
  });

  testWidgets('bubbles in a run sit 2px apart, and 10px when the sender '
      'changes', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('a', 'me', m: 0));
    store.add(_msg('b', 'me', m: 1));
    store.add(_msg('c', 'kaitlyn', m: 2));

    await _pump(tester, container);
    expect(_rect(tester, 'b').top - _rect(tester, 'a').bottom, 2);
    expect(_rect(tester, 'c').top - _rect(tester, 'b').bottom, 10);
  });

  testWidgets('a reacted bubble mid-run still clears the bubble above for its '
      'badge', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('a', 'kaitlyn', m: 0));
    store.add(_msg('b', 'kaitlyn', m: 1, reactions: const {'me': '❤️'}));
    store.add(_msg('c', 'kaitlyn', m: 2));

    await _pump(tester, container);
    final badge = tester.getRect(find.byKey(const Key('reaction-badge-b')));
    expect(badge.top, greaterThanOrEqualTo(_rect(tester, 'a').bottom));
    // The badge's room is on top of the run gap, not in place of it.
    expect(_rect(tester, 'b').top - _rect(tester, 'a').bottom, greaterThan(2));
    // The run is unbroken: b is a middle bubble, c still ends the run.
    expect(_tail(tester, 'b'), isFalse);
    expect(_tail(tester, 'c'), isTrue);
  });

  testWidgets('the last bubble keeps its tail, and its row, across the '
      'optimistic reconcile', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('srv-1', 'me', m: 0));
    store.add(
      _msg(
        'cli-2',
        'me',
        m: 1,
        clientMsgId: 'cli-2',
        sendStatus: SendStatus.sending,
      ),
    );

    await _pump(tester, container);
    expect(_tail(tester, 'cli-2'), isTrue);
    final before = tester.renderObject(
      find.byKey(const Key('bubble-bg-cli-2')),
    );

    store.reconcile('cli-2', _msg('srv-2', 'me', m: 1));
    await tester.pump();

    expect(_tail(tester, 'cli-2'), isTrue);
    expect(_tail(tester, 'srv-1'), isFalse);
    // Same render object: the row was updated in place, not remounted.
    expect(
      tester.renderObject(find.byKey(const Key('bubble-bg-cli-2'))),
      same(before),
    );
  });

  for (final palette in [AppPalette.light, AppPalette.dark]) {
    testWidgets('my bubbles have no outline; the partner\'s has only its faint '
        'edge (${palette.brightness.name})', (tester) async {
      final container = await _container(tester);
      final store = container.read(messageStoreProvider('r1').notifier);
      store.add(_msg('mine', 'me', m: 0));
      store.add(_voiceMsg('mine-voice', 'me', m: 1));
      store.add(_msg('theirs', 'kaitlyn', m: 2));
      store.add(_voiceMsg('theirs-voice', 'kaitlyn', m: 3));

      await _pump(tester, container, palette: palette);
      for (final key in ['mine', 'mine-voice']) {
        expect(_painter(tester, key).border, isNull, reason: key);
      }
      for (final key in ['theirs', 'theirs-voice']) {
        expect(
          _painter(tester, key).border,
          palette.bubblePartnerEdge,
          reason: key,
        );
      }
      // Faint: about half the strength of the old full borderSoft line.
      expect(palette.bubblePartnerEdge.a, lessThan(0.6));
    });
  }

  testWidgets('a channel line breaks bubble runs and has no reply or react '
      'actions', (tester) async {
    final container = await _container(tester);
    final store = container.read(messageStoreProvider('r1').notifier);
    store.add(_msg('a', 'kaitlyn', m: 0));
    store.add(_channelLine('c', 'kaitlyn', m: 1));
    store.add(_msg('b', 'kaitlyn', m: 2));
    await _pump(tester, container);

    expect(find.text('Kaitlyn renamed the channel to Us'), findsOneWidget);
    // Same sender, but the line splits the run: each bubble is a whole run.
    expect(_tail(tester, 'a'), isTrue);
    expect(_tail(tester, 'b'), isTrue);

    await tester.longPress(find.byKey(const Key('channel-line-c')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('action-reply')), findsNothing);

    // The harness does open the menu for an ordinary bubble.
    await tester.longPress(find.text('body a'));
    await pumpUntilFound(tester, find.byKey(const Key('action-reply')));
  });

  testWidgets('my own channel line says You', (tester) async {
    final container = await _container(tester);
    container
        .read(messageStoreProvider('r1').notifier)
        .add(_channelLine('c', 'me', m: 0));
    await _pump(tester, container);

    expect(find.text('You renamed the channel to Us'), findsOneWidget);
  });

  testWidgets('a failed channel line offers tap to retry', (tester) async {
    final container = await _container(tester);
    container
        .read(messageStoreProvider('r1').notifier)
        .add(
          _channelLine(
            'c',
            'me',
            m: 0,
            clientMsgId: 'cm1',
            sendStatus: SendStatus.failed,
          ),
        );
    final retried = <String>[];
    await _pump(tester, container, onRetry: retried.add);

    expect(find.textContaining('Not sent. Tap to retry.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('channel-line-cm1')));
    await tester.pump();
    expect(retried, ['cm1']);
  });
}
