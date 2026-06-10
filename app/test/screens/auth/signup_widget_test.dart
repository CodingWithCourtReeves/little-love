import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/screens/auth/signup.dart';

void main() {
  testWidgets('shows username field and disabled Create button initially', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SignupScreen(onPhraseReady: (_, _) {})),
    );
    expect(find.byType(TextField), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('valid username enables Create button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SignupScreen(onPhraseReady: (_, _) {})),
    );
    await tester.enterText(find.byType(TextField), 'court');
    await tester.pump();
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets(
    'invalid username (UPPER) shows error and keeps button disabled',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SignupScreen(onPhraseReady: (_, _) {})),
      );
      await tester.enterText(find.byType(TextField), 'Court');
      await tester.pump();
      expect(find.text('3–20 chars, lowercase a-z 0-9 _'), findsOneWidget);
      final btn = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(btn.onPressed, isNull);
    },
  );

  testWidgets(
    'tapping Create shows exactly 12 numbered words without firing onPhraseReady',
    (tester) async {
      String? capturedUser;
      String? capturedPhrase;
      await tester.pumpWidget(
        MaterialApp(
          home: SignupScreen(
            onPhraseReady: (u, p) {
              capturedUser = u;
              capturedPhrase = p;
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'court');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      for (var i = 1; i <= 12; i++) {
        expect(find.textContaining('$i.'), findsWidgets);
      }
      // onPhraseReady must NOT fire until the user confirms they've saved
      // the phrase (spec §3.1 step 6).
      expect(capturedUser, isNull);
      expect(capturedPhrase, isNull);
    },
  );

  testWidgets(
    "tapping 'I've saved these words' fires onPhraseReady with the phrase",
    (tester) async {
      String? capturedUser;
      String? capturedPhrase;
      await tester.pumpWidget(
        MaterialApp(
          home: SignupScreen(
            onPhraseReady: (u, p) {
              capturedUser = u;
              capturedPhrase = p;
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'court');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('phrase-saved')));
      await tester.pumpAndSettle();
      expect(capturedUser, 'court');
      expect(capturedPhrase, isNotNull);
      expect(capturedPhrase!.split(' ').length, 12);
    },
  );
}
