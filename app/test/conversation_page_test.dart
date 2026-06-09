import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation_page.dart';
import 'package:littlelove/theme/twilight.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  testWidgets('renders inbound and outbound bubbles distinctly', (
    tester,
  ) async {
    final messages = <Msg>[
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
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: messages,
          onSend: (_) {},
        ),
      ),
    );
    expect(find.text('hey love'), findsOneWidget);
    expect(find.text('long. miss you.'), findsOneWidget);
    expect(find.text('Kaitlyn'), findsWidgets); // appears in header / metadata
  });

  testWidgets('tapping send button fires onSend', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: const [],
          onSend: (text) => sent = text,
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 'hi');
  });

  testWidgets('day separators appear between messages on different days', (
    tester,
  ) async {
    final messages = <Msg>[
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'from earlier',
        ts: DateTime.now().toUtc().subtract(const Duration(days: 2)),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'today',
        ts: DateTime.now().toUtc(),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: messages,
          onSend: (_) {},
        ),
      ),
    );
    expect(find.text('Today'), findsOneWidget);
    // Two days ago is either a weekday name or a date; either way it's not "Today".
    expect(
      find.byWidgetPredicate((w) {
        if (w is Text && w.data != null) {
          return w.data == 'Yesterday' ||
              RegExp(
                r'^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)',
              ).hasMatch(w.data!);
        }
        return false;
      }),
      findsWidgets,
    );
  });

  testWidgets(
    'gap header appears between messages with a 1+ hour gap on same day',
    (tester) async {
      final morning = DateTime(2026, 6, 9, 8, 0).toUtc();
      final evening = DateTime(2026, 6, 9, 20, 0).toUtc();
      final messages = <Msg>[
        Msg(
          id: '1',
          from: 'court',
          to: 'kaitlyn',
          body: 'morning ping',
          ts: morning,
        ),
        Msg(
          id: '2',
          from: 'kaitlyn',
          to: 'court',
          body: 'evening reply',
          ts: evening,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTwilightTheme(),
          home: ConversationPage(
            meUsername: 'court',
            contactDisplayName: 'Kaitlyn',
            messages: messages,
            onSend: (_) {},
          ),
        ),
      );
      // 8 PM in the user's local time should appear as a gap header.
      final localEvening = evening.toLocal();
      final hour12 = localEvening.hour == 0
          ? 12
          : (localEvening.hour > 12
                ? localEvening.hour - 12
                : localEvening.hour);
      final ampm = localEvening.hour < 12 ? 'AM' : 'PM';
      final expectedTime =
          '$hour12:${localEvening.minute.toString().padLeft(2, '0')} $ampm';
      expect(find.text(expectedTime), findsOneWidget);
    },
  );

  testWidgets('bubble has a Tooltip showing the full timestamp', (
    tester,
  ) async {
    final messages = <Msg>[
      Msg(
        id: '1',
        from: 'court',
        to: 'kaitlyn',
        body: 'hello',
        ts: DateTime(2026, 6, 9, 17, 14).toUtc(),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: messages,
          onSend: (_) {},
        ),
      ),
    );
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: find.text('hello'), matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, contains(' at '));
  });

  testWidgets('emoji-only messages render at large size without a bubble', (
    tester,
  ) async {
    final messages = <Msg>[
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: '💔',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: messages,
          onSend: (_) {},
        ),
      ),
    );

    final emojiText = tester.widget<Text>(find.text('💔'));
    expect(emojiText.style?.fontSize, 48);

    final regularText = tester.widget<Text>(find.text('hey love'));
    expect(regularText.style?.fontSize, 16);
  });

  testWidgets('emoji button toggles the picker panel', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: const [],
          onSend: (_) {},
        ),
      ),
    );

    expect(find.byKey(const Key('emoji-panel')), findsNothing);

    await tester.tap(find.byKey(const Key('emoji-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('emoji-panel')), findsOneWidget);

    await tester.tap(find.byKey(const Key('emoji-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('emoji-panel')), findsNothing);
  });

  testWidgets('multi-line text is preserved through onSend', (tester) async {
    String? sent;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTwilightTheme(),
        home: ConversationPage(
          meUsername: 'court',
          contactDisplayName: 'Kaitlyn',
          messages: const [],
          onSend: (text) => sent = text,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('composer')),
      'line one\nline two\n\nline four',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 'line one\nline two\n\nline four');
  });
}
