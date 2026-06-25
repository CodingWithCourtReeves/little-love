import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/onboarding/phrase_input.dart';

Widget _host(void Function(String) onChanged) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: PhraseInput(onChanged: onChanged)),
  ),
);

void main() {
  testWidgets('pasting a phrase into one box distributes across all 12', (
    tester,
  ) async {
    String emitted = '';
    await tester.pumpWidget(_host((p) => emitted = p));

    const phrase =
        'lunar garden anchor velvet ember willow '
        'copper lantern pepper ridge marble otter';
    await tester.enterText(find.byKey(const ValueKey('phrase-word-0')), phrase);
    await tester.pump();

    expect(emitted.split(' ').length, 12);
    expect(emitted, phrase);
    // First and last boxes hold the first and last words.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('phrase-word-0')))
          .controller!
          .text,
      'lunar',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('phrase-word-11')))
          .controller!
          .text,
      'otter',
    );
  });

  testWidgets('typing a prefix surfaces a BIP39 autocomplete suggestion', (
    tester,
  ) async {
    await tester.pumpWidget(_host((_) {}));
    await tester.tap(find.byKey(const ValueKey('phrase-word-0')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('phrase-word-0')), 'aban');
    await tester.pump();
    // 'aban' uniquely completes to 'abandon' in the BIP39 list.
    expect(find.text('abandon'), findsOneWidget);
  });
}
