import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation_page.dart';
import 'package:littlelove/theme/hearth.dart';
import 'package:littlelove/wire/message.dart';

void main() {
  testWidgets('renders inbound and outbound bubbles distinctly', (tester) async {
    final messages = <Msg>[
      Msg(
        id: '1', from: 'kaitlyn', to: 'court', body: 'long. miss you.',
        ts: DateTime.utc(2026, 6, 9, 17, 3),
      ),
      Msg(
        id: '2', from: 'court', to: 'kaitlyn', body: 'hey love',
        ts: DateTime.utc(2026, 6, 9, 17, 2),
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      theme: buildHearthTheme(),
      home: ConversationPage(
        meUsername: 'court',
        contactDisplayName: 'Kaitlyn',
        messages: messages,
        onSend: (_) {},
      ),
    ));
    expect(find.text('hey love'), findsOneWidget);
    expect(find.text('long. miss you.'), findsOneWidget);
    expect(find.text('Kaitlyn'), findsWidgets); // appears in header / metadata
  });

  testWidgets('tapping send button fires onSend', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(
      theme: buildHearthTheme(),
      home: ConversationPage(
        meUsername: 'court',
        contactDisplayName: 'Kaitlyn',
        messages: const [],
        onSend: (text) => sent = text,
      ),
    ));
    await tester.enterText(find.byKey(const Key('composer')), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 'hi');
  });

  testWidgets('multi-line text is preserved through onSend', (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(
      theme: buildHearthTheme(),
      home: ConversationPage(
        meUsername: 'court',
        contactDisplayName: 'Kaitlyn',
        messages: const [],
        onSend: (text) => sent = text,
      ),
    ));
    await tester.enterText(
      find.byKey(const Key('composer')),
      'line one\nline two\n\nline four',
    );
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    expect(sent, 'line one\nline two\n\nline four');
  });
}
