import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/conversation_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/reply_quote.dart';
import 'package:littlelove/conversation/reply_ref.dart';
import 'package:littlelove/identity/account_local.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';

import '../support/test_read_state.dart';

/// WCAG contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

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

const _photo = AttachmentDescriptor(
  blobKey: 'img-1',
  contentKeyB64: 'k',
  nonceB64: 'n',
  mime: 'image/jpeg',
  filename: 'pic.jpg',
  size: 1234,
  width: 100,
  height: 80,
  durationMs: null,
  thumbB64: '',
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

const _long =
    'Did you see the photo I sent your mom? She said it made her whole week '
    'and she already put it on the fridge next to the one from the beach';

const _quote = ReplyRef(
  id: 'orig',
  author: 'kaitlyn',
  kind: 'text',
  text: _long,
);

void main() {
  test("the quoted author's name passes 4.5:1 on its inset, in either "
      'bubble, light and dark', () {
    for (final p in [AppPalette.light, AppPalette.dark]) {
      for (final onUserBubble in [true, false]) {
        final c = ReplyQuote.colorsFor(p, onUserBubble: onUserBubble);
        final bubble = onUserBubble ? p.bubbleUserBg : p.bubblePartnerBg;
        expect(
          _contrast(c.name, Color.alphaBlend(c.inset, bubble)),
          greaterThanOrEqualTo(4.5),
          reason: '${p.brightness.name}, onUserBubble: $onUserBubble',
        );
      }
    }
  });

  testWidgets('a reply quote shows up to two lines, with a 3px accent bar, '
      'in text, media and voice bubbles', (tester) async {
    final container = ProviderContainer(
      overrides: [
        accountProvider.overrideWith((_) async => _account),
        hermeticReadStateStore(),
        // Media and voice bubbles read the socket; never connect in tests.
        liveConnectionProvider.overrideWith(
          (_) => Completer<LiveConnection>().future,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(accountProvider.future);
    final store = container.read(messageStoreProvider('r1').notifier);
    Msg reply(String id, int m, {AttachmentDescriptor? attachment}) => Msg(
      id: id,
      from: 'me',
      to: 'r1',
      body: attachment == null ? 'replying' : '',
      ts: DateTime(2026, 6, 13, 10, m),
      attachment: attachment,
      replyTo: _quote,
    );
    store.add(reply('r-text', 0));
    store.add(reply('r-media', 1, attachment: _photo));
    store.add(reply('r-voice', 2, attachment: _voice));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
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

    const p = AppPalette.light;
    for (final id in ['r-text', 'r-media', 'r-voice']) {
      final quote = find.byKey(Key('reply-quote-$id'));
      expect(quote, findsOneWidget, reason: id);
      final textFinder = find.descendant(
        of: quote,
        matching: find.byKey(const Key('reply-quote-text')),
      );
      expect(tester.widget<Text>(textFinder).maxLines, 2, reason: id);
      // The long quote really wraps onto a second line (13px text).
      expect(tester.getSize(textFinder).height, greaterThan(26), reason: id);
      final box = tester.widget<Container>(
        find.descendant(of: quote, matching: find.byType(Container)).first,
      );
      final deco = box.decoration! as BoxDecoration;
      final bar = (deco.border! as Border).left;
      expect(bar.width, 3, reason: id);
      expect(bar.color, p.accentUser, reason: id);
      expect(deco.color, p.replyInsetOnUser, reason: id);
      expect(
        tester
            .widget<Text>(
              find.descendant(of: quote, matching: find.text('kaitlyn')),
            )
            .style!
            .color,
        p.replyNameOnUser,
        reason: id,
      );
    }
  });
}
