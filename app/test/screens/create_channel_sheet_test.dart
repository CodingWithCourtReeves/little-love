import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/pending_channel_actions.dart';
import 'package:littlelove/screens/create_chat/create_channel_sheet.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

import '../support/widget_waits.dart';

class _Conn implements LiveConnection {
  final List<Object> sent = [];
  @override
  Stream<RoomServerFrame> get incoming => const Stream.empty();
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async {}
}

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

  group('the new-channel picture', () {
    Future<(ProviderContainer, _Conn)> open(WidgetTester t) async {
      final conn = _Conn();
      final c = ProviderContainer(
        overrides: [liveConnectionProvider.overrideWith((_) async => conn)],
      );
      addTearDown(c.dispose);
      await c.read(liveConnectionProvider.future);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showCreateChannelSheet(context, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await pumpUntilFound(t, find.byKey(const Key('channel-name-field')));
      await t.pumpAndSettle(); // the slide-in animation
      await t.enterText(find.byKey(const Key('channel-name-field')), 'Trips');
      await t.pump();
      return (c, conn);
    }

    testWidgets(
      'picking a picture in the new-channel sheet registers it for the created room',
      (t) async {
        final (c, conn) = await open(t);
        await t.tap(find.byKey(const Key('channel-name-picture')));
        await pumpUntilFound(t, find.byKey(const Key('channel-picture-done')));
        await t.pumpAndSettle(); // the slide-in animation
        await t.tap(find.byKey(const Key('channel-symbol-moon')));
        await t.pump();
        await t.tap(find.byKey(const Key('channel-color-sky')));
        await t.pump();
        await t.tap(find.byKey(const Key('channel-picture-done')));
        await pumpUntilTrue(
          t,
          () =>
              find.byKey(const Key('channel-picture-done')).evaluate().isEmpty,
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('create-channel-button')));
        await pumpUntilTrue(t, () => conn.sent.isNotEmpty);

        final created = c
            .read(pendingChannelActionsProvider)
            .takeCreated('trips');
        expect(created, isA<ChooseSymbol>());
        expect((created as ChooseSymbol).symbol, ChannelSymbol.moon);
        expect(created.color, ChannelColor.sky);
        expect((conn.sent.single as Map)['kind'], 'CreateRoom');
      },
    );

    testWidgets('skipping the picture registers nothing', (t) async {
      final (c, conn) = await open(t);
      await t.tap(find.byKey(const Key('create-channel-button')));
      await pumpUntilTrue(t, () => conn.sent.isNotEmpty);
      expect(
        c.read(pendingChannelActionsProvider).takeCreated('trips'),
        isNull,
      );
    });
  });
}
