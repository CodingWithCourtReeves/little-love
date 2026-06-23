import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/chat_info_page.dart';
import 'package:littlelove/conversation/link_preview.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Room _room() => Room(
  roomId: 'roomA',
  name: 'Kaitlyn',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'A', x25519PubBase64: 'B'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'C', x25519PubBase64: 'D'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

const _descriptor = AttachmentDescriptor(
  blobKey: 'blob-1',
  contentKeyB64: 'k',
  nonceB64: 'n',
  mime: 'image/jpeg',
  filename: 'pic.jpg',
  size: 1234,
  width: 100,
  height: 80,
  durationMs: null,
  thumbB64: 'thumb',
);

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: buildAppTheme(AppPalette.light),
    home: ChatInfoPage(room: _room(), selfUsername: 'court'),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('header shows the partner name; tabs render media and links', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'look https://example.com',
        ts: DateTime.utc(2026, 6, 10, 9),
        linkPreview: const LinkPreview(
          url: 'https://example.com',
          title: 'Example',
        ),
      ),
      Msg(
        id: '2',
        from: 'court',
        to: 'kaitlyn',
        body: '',
        ts: DateTime.utc(2026, 6, 10, 10),
        attachment: _descriptor,
      ),
    ]);
    await tester.pumpWidget(_app(c));
    await tester.pump();

    expect(find.byKey(const Key('chat-info-name')), findsOneWidget);
    expect(find.text('Kaitlyn'), findsOneWidget);

    // Media tab (default) shows the one attachment tile.
    expect(find.byKey(const Key('chat-info-media-grid')), findsOneWidget);
    expect(find.byKey(const Key('chat-info-media-0')), findsOneWidget);

    // Switch to Links: the previewed link row renders by its title.
    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-info-link-0')), findsOneWidget);
    expect(find.text('Example'), findsOneWidget);
  });

  testWidgets('a link with a preview image shows it instead of the icon', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'kaitlyn',
        to: 'court',
        body: 'https://example.com',
        ts: DateTime.utc(2026, 6, 10, 9),
        linkPreview: LinkPreview(
          url: 'https://example.com',
          title: 'Example',
          imageB64: base64.encode(List<int>.filled(16, 7)),
        ),
      ),
    ]);
    await tester.pumpWidget(_app(c));
    await tester.pump();
    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();

    // The leading thumbnail is an Image (decoded preview), not the link icon.
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-info-link-0')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty states show when there is no media / no links', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // No messages at all.
    await tester.pumpWidget(_app(c));
    await tester.pump();
    expect(find.text('No media yet'), findsOneWidget);

    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('Voice messages are coming soon'), findsOneWidget);

    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.text('No links yet'), findsOneWidget);
  });

  testWidgets('the stubbed action buttons toast "coming soon"', (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-info-call')));
    await tester.pump();
    expect(find.text('Calls are coming soon'), findsOneWidget);

    // Let the toast's auto-dismiss timer + fade run out so it doesn't leak.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
