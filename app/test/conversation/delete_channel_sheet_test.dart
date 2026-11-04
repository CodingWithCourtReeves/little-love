import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/delete_channel_sheet.dart';
import 'package:littlelove/inbox/channel_deletion.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';

final _travel = Room(
  roomId: 'chan',
  name: 'Travel',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'a', x25519PubBase64: 'b'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'c', x25519PubBase64: 'd'),
  ],
  createdAt: DateTime.utc(2026),
);

/// Opens the sheet over a bare page; [outcome] is what onDelete returns.
Future<List<int>> _open(
  WidgetTester tester, {
  DeleteChannelOutcome outcome = DeleteChannelOutcome.deleted,
}) async {
  final calls = <int>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDeleteChannelSheet(
                context,
                room: _travel,
                selfUsername: 'court',
                onDelete: () async {
                  calls.add(1);
                  return outcome;
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return calls;
}

FilledButton _confirm(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const Key('delete-channel-confirm')),
);

void main() {
  testWidgets('shows the name, the warning and the prompt', (tester) async {
    await _open(tester);
    expect(find.text('Delete Travel?'), findsOneWidget);
    expect(
      find.text(
        'This deletes the channel and all its messages for both of you. '
        'This can\'t be undone.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Type Travel to confirm', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('delete stays disabled until the typed name matches', (
    tester,
  ) async {
    await _open(tester);
    expect(_confirm(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      'trave',
    );
    await tester.pump();
    expect(_confirm(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      ' travel ',
    );
    await tester.pump();
    expect(_confirm(tester).onPressed, isNotNull);
  });

  testWidgets('confirming buzzes a medium haptic, deletes and closes', (
    tester,
  ) async {
    final haptics = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final calls = await _open(tester);
    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      'Travel',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('delete-channel-confirm')));
    await tester.pumpAndSettle();

    expect(calls, [1]);
    expect(haptics, ['HapticFeedbackType.mediumImpact']);
    expect(find.text('Delete Travel?'), findsNothing);
  });

  testWidgets('offline keeps the sheet open and says so', (tester) async {
    await _open(tester, outcome: DeleteChannelOutcome.offline);
    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      'Travel',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-channel-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('You\'re offline. Connect to delete this channel.'),
      findsOneWidget,
    );
    expect(find.text('Delete Travel?'), findsOneWidget);
    expect(_confirm(tester).onPressed, isNotNull);
  });

  testWidgets('a failure keeps the sheet open and says so', (tester) async {
    await _open(tester, outcome: DeleteChannelOutcome.failed);
    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      'Travel',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-channel-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('Couldn\'t delete the channel. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Delete Travel?'), findsOneWidget);
  });

  testWidgets('the last chat keeps the sheet open and says it can\'t go', (
    tester,
  ) async {
    await _open(tester, outcome: DeleteChannelOutcome.lastRoom);
    await tester.enterText(
      find.byKey(const Key('delete-channel-field')),
      'Travel',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-channel-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.text('This is your only chat, so it can\'t be deleted.'),
      findsOneWidget,
    );
    expect(find.text('Delete Travel?'), findsOneWidget);
  });

  testWidgets('cancel closes without deleting', (tester) async {
    final calls = await _open(tester);
    await tester.tap(find.byKey(const Key('delete-channel-cancel')));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.text('Delete Travel?'), findsNothing);
  });
}
