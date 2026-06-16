import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/screens/create_chat/create_channel_sheet.dart';

void main() {
  group('formatChannelName', () {
    test('lowercases and dashes spaces', () {
      expect(formatChannelName('Date Ideas'), 'date-ideas');
    });
    test('collapses repeated spaces/dashes', () {
      expect(formatChannelName('weekly   check--in'), 'weekly-check-in');
    });
    test('strips invalid characters', () {
      expect(formatChannelName('trip!! 2026 ✨'), 'trip-2026');
    });
    test('trims leading/trailing dashes', () {
      expect(formatChannelName('  -hello-  '), 'hello');
    });
  });

  testWidgets('typing updates the live #preview', (t) async {
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                return TextButton(
                  onPressed: () => showCreateChannelSheet(context, ref),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const Key('channel-name-field')),
      'Date Ideas',
    );
    await t.pump();
    expect(find.text('Preview:  #date-ideas'), findsOneWidget);
    expect(find.text('Create #date-ideas'), findsOneWidget);
  });
}
