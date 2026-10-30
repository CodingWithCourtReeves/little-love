import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/chat_info_chrome.dart';
import 'package:littlelove/conversation/chat_info_page.dart';
import 'package:littlelove/conversation/link_preview.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/shared_media_page.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/profile/avatar.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wallpaper/wallpaper_background.dart';
import 'package:littlelove/wallpaper/wallpaper_screen.dart';
import 'package:littlelove/wallpaper/wallpaper_selection.dart';
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

/// The partner DM: unnamed, just the two of you.
Room _dm() => Room(
  roomId: 'roomA',
  name: '',
  members: _room().members,
  createdAt: DateTime.utc(2026, 6, 10),
);

Widget _app(ProviderContainer c, {Room? room}) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: buildAppTheme(AppPalette.light),
    home: ChatInfoPage(room: room ?? _room(), selfUsername: 'court'),
  ),
);

/// WCAG contrast ratio between two opaque colors.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('header shows the name; the shared gallery renders media and '
      'links', (tester) async {
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

    await tester.tap(find.byKey(const Key('chat-info-shared-media')));
    await tester.pumpAndSettle();
    // The gallery opens on Photos, with the one attachment tile.
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
    await tester.ensureVisible(find.byKey(const Key('chat-info-shared-links')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-info-shared-links')));
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
    // No messages at all: every Shared row says None.
    await tester.pumpWidget(_app(c));
    await tester.pump();
    expect(find.text('None'), findsNWidgets(3));
    expect(find.byKey(const Key('chat-info-media-strip')), findsNothing);
    await tester.tap(find.byKey(const Key('chat-info-shared-media')));
    await tester.pumpAndSettle();
    expect(find.text('No photos or videos yet'), findsOneWidget);

    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.text('No voice messages yet'), findsOneWidget);

    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.text('No links yet'), findsOneWidget);
  });

  testWidgets('the search action opens the in-channel search page', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c));
    await tester.pump();

    // Call + Video place real calls; Search now opens the search page (no
    // stubbed actions remain). The empty query touches no DB, so no override
    // is needed here.
    await tester.tap(find.byKey(const Key('chat-info-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-search-field')), findsOneWidget);
  });

  testWidgets('rename row is hidden without onRename (the partner DM)', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(_app(c)); // _app passes no onRename
    await tester.pump();
    expect(find.byKey(const Key('chat-info-rename')), findsNothing);
  });

  testWidgets('rename row shows + fires when onRename is provided (channel)', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    String? renamed;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: ChatInfoPage(
            room: _room(),
            selfUsername: 'court',
            onRename: (n) => renamed = n,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('chat-info-rename')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-info-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rename-dialog-field')),
      'Trip planning',
    );
    await tester.tap(find.byKey(const Key('rename-dialog-save')));
    await tester.pumpAndSettle();
    expect(renamed, 'Trip planning');
  });

  group('on the wallpaper (#91)', () {
    testWidgets('chat info sits on the chat\'s wallpaper', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(ChatInfoPage),
          matching: find.byType(WallpaperBackground),
        ),
        findsOneWidget,
      ); // The page runs behind its transparent app bar, but the content starts
      // below the toolbar, never under the back pill.
      expect(
        tester.getRect(find.byType(Avatar)).top,
        greaterThanOrEqualTo(kToolbarHeight),
      );
    });

    testWidgets("the partner DM's header shows the partner's presence", (
      tester,
    ) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c, room: _dm()));
      await tester.pump();
      expect(find.text('Kaitlyn'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-info-subtitle')),
          matching: find.text('offline'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("a channel's header shows its own name and who it's with", (
      tester,
    ) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final channel = Room(
        roomId: 'roomA',
        name: 'Trip planning',
        members: _room().members,
        createdAt: DateTime.utc(2026, 6, 10),
      );
      await tester.pumpWidget(_app(c, room: channel));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-info-name'))).data,
        'Trip planning',
      );
      expect(find.text('Channel with Kaitlyn'), findsOneWidget);
    });

    testWidgets('Call, Video and Search are equal-width tiles, at least 44pt '
        'tall', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      await tester.pump();
      final rects = [
        for (final k in [
          'chat-info-call',
          'chat-info-video',
          'chat-info-search',
        ])
          tester.getRect(find.byKey(Key(k))),
      ];
      for (final r in rects) {
        expect(r.width, moreOrLessEquals(rects.first.width, epsilon: 0.5));
        expect(r.height, greaterThanOrEqualTo(44));
      }
      // Together they span the row, not a centred cluster of small circles.
      expect(rects.first.width * 3, greaterThan(300));
    });

    test('header text and tile labels pass 4.5:1 over the veil on every '
        'wallpaper, light and dark', () {
      for (final wallpaper in WallpaperGradient.values) {
        final p = AppPalette.of(wallpaper.brightness);
        for (final spot in [...wallpaper.colors, wallpaper.base]) {
          for (final ground in [
            spot,
            Color.alphaBlend(wallpaper.doodleInk, spot),
          ]) {
            final veil = Color.alphaBlend(
              p.bgCanvas.withValues(alpha: veilAlpha),
              ground,
            );
            final card = Color.alphaBlend(infoCardColor(p), veil);
            final reason = '${wallpaper.label} at $ground';
            expect(
              _contrast(p.textPrimary, veil),
              greaterThanOrEqualTo(4.5),
              reason: 'name, $reason',
            );
            expect(
              _contrast(p.separatorText, veil),
              greaterThanOrEqualTo(4.5),
              reason: 'subtitle, $reason',
            );
            expect(
              _contrast(p.accentUser, card),
              greaterThanOrEqualTo(4.5),
              reason: 'tile label, $reason',
            );
          }
        }
      }
    });
  });

  group('the Shared card (#92)', () {
    AttachmentDescriptor photo(String key) => AttachmentDescriptor(
      blobKey: key,
      contentKeyB64: 'k',
      nonceB64: 'n',
      mime: 'image/jpeg',
      filename: '$key.jpg',
      size: 1234,
      width: 100,
      height: 80,
      durationMs: null,
      thumbB64: 'thumb',
    );
    final voice = AttachmentDescriptor(
      blobKey: 'v',
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

    /// Six photos (p0 oldest … p5 newest), two voice memos and one link.
    List<Msg> history() => [
      for (var i = 0; i < 6; i++)
        Msg(
          id: 'p$i',
          from: 'kaitlyn',
          to: 'court',
          body: '',
          ts: DateTime.utc(2026, 6, 10, 9, i),
          attachment: photo('p$i'),
        ),
      for (var i = 0; i < 2; i++)
        Msg(
          id: 'v$i',
          from: 'court',
          to: 'kaitlyn',
          body: '',
          ts: DateTime.utc(2026, 6, 10, 10, i),
          attachment: voice,
        ),
      Msg(
        id: 'l0',
        from: 'kaitlyn',
        to: 'court',
        body: 'https://example.com',
        ts: DateTime.utc(2026, 6, 10, 11),
      ),
    ];

    Widget app(
      ProviderContainer c, {
      void Function(AttachmentDescriptor d)? onOpen,
    }) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: ChatInfoPage(
          room: _room(),
          selfUsername: 'court',
          onOpenAttachment: onOpen,
        ),
      ),
    );

    Finder valueOf(String row, String value) =>
        find.descendant(of: find.byKey(Key(row)), matching: find.text(value));

    testWidgets('counts each kind, with the four newest photos as a strip', (
      tester,
    ) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(messageStoreProvider('roomA').notifier).setAll(history());
      await tester.pumpWidget(app(c));
      await tester.pump();

      expect(valueOf('chat-info-shared-media', '6'), findsOneWidget);
      expect(valueOf('chat-info-shared-voice', '2'), findsOneWidget);
      expect(valueOf('chat-info-shared-links', '1'), findsOneWidget);
      final strip = [
        for (var i = 0; i < 4; i++)
          tester
              .widget<SharedMediaTile>(find.byKey(Key('chat-info-strip-$i')))
              .descriptor
              .blobKey,
      ];
      expect(strip, ['p5', 'p4', 'p3', 'p2']);
      expect(find.byKey(const Key('chat-info-strip-4')), findsNothing);
    });

    testWidgets('each row opens the gallery on its own kind', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(messageStoreProvider('roomA').notifier).setAll(history());
      await tester.pumpWidget(app(c));
      await tester.pump();

      await tester.ensureVisible(
        find.byKey(const Key('chat-info-shared-voice')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-info-shared-voice')));
      await tester.pumpAndSettle();
      expect(find.byType(SharedMediaPage), findsOneWidget);
      expect(find.byKey(const Key('chat-info-voice-list')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-info-back')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('chat-info-shared-links')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-info-shared-links')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-info-links-list')), findsOneWidget);
    });

    testWidgets('a shared photo opens in the viewer, from the strip and from '
        'the gallery', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(messageStoreProvider('roomA').notifier).setAll(history());
      final opened = <String>[];
      await tester.pumpWidget(app(c, onOpen: (d) => opened.add(d.blobKey)));
      await tester.pump();

      await tester.tap(find.byKey(const Key('chat-info-strip-0')));
      expect(opened, ['p5']);

      await tester.tap(find.byKey(const Key('chat-info-shared-media')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-info-media-2')));
      expect(opened, ['p5', 'p3']);
    });
  });

  group('This chat and the encryption note (#93)', () {
    testWidgets('the Wallpaper row shows the current wallpaper and opens the '
        'picker', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c));
      await tester.pump();
      final row = find.byKey(const Key('chat-info-wallpaper'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(WallpaperSelection.defaults.gradient.label),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(WallpaperScreen), findsOneWidget);
    });

    testWidgets('the encryption note names the partner', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c, room: _dm()));
      await tester.pump();
      // The last thing on the page, below the fold in the test window.
      await tester.scrollUntilVisible(
        find.byKey(const Key('chat-info-e2ee')),
        200,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('chat-info-e2ee')),
          matching: find.text(
            'Messages, calls and media are end-to-end encrypted. '
            'Only you and Kaitlyn can see them.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the partner DM has no Rename row; This chat still shows', (
      tester,
    ) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(c, room: _dm()));
      await tester.pump();
      expect(find.byKey(const Key('chat-info-wallpaper')), findsOneWidget);
      expect(find.byKey(const Key('chat-info-rename')), findsNothing);
    });
  });
}
