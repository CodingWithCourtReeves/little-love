import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/channel_picture_provider.dart';
import 'package:littlelove/channel/channel_tile.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';

Widget _host(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildAppTheme(AppPalette.light),
        home: Scaffold(body: Center(child: child)),
      ),
    );

// 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Color? _tintOf(WidgetTester t) {
  final box = t.widget<ColoredBox>(
    find.descendant(
      of: find.byType(ChannelPictureView),
      matching: find.byType(ColoredBox),
    ),
  );
  return box.color;
}

void main() {
  testWidgets('symbol picture draws the symbol on its swatch', (t) async {
    await t.pumpWidget(
      _host(
        const ChannelPictureView(
          name: 'trips',
          colorSeed: 'r1',
          picture: SymbolPicture(ChannelSymbol.paw, ChannelColor.sage),
        ),
      ),
    );
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(
      _tintOf(t),
      AppPalette.light.channelSwatches[ChannelColor.sage.index].tint,
    );
  });

  testWidgets('every symbol asset exists in the bundle and renders', (t) async {
    for (final s in ChannelSymbol.values) {
      final svg = await t.runAsync(
        () => rootBundle.loadString('assets/channel_symbols/${s.name}.svg'),
      );
      expect(svg, contains('<svg'), reason: s.name);
      await t.pumpWidget(
        _host(
          ChannelPictureView(
            name: 'x',
            colorSeed: 'r1',
            picture: SymbolPicture(s, ChannelColor.rose),
          ),
        ),
      );
      expect(find.byType(SvgPicture), findsOneWidget, reason: s.name);
    }
  });

  testWidgets('photo picture without a downloaded file shows the inline '
      'thumbnail', (t) async {
    final room = Room(
      roomId: 'room-1',
      name: 'trips',
      members: const [],
      createdAt: DateTime(2026),
    );
    final desc = AttachmentDescriptor(
      blobKey: 'k',
      contentKeyB64: '',
      nonceB64: '',
      mime: 'image/jpeg',
      filename: 'p.jpg',
      size: 1,
      width: 512,
      height: 512,
      durationMs: null,
      thumbB64: base64Encode(_png),
    );
    await t.pumpWidget(
      _host(
        ChannelTile(room: room, selfUsername: 'me'),
        overrides: [
          currentChannelPictureProvider(
            'room-1',
          ).overrideWithValue(PhotoPicture(desc)),
          channelPhotoFileProvider('room-1').overrideWith((ref) => null),
        ],
      ),
    );
    await t.pump();
    final image = t.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(
      provider is ResizeImage && provider.imageProvider is MemoryImage,
      isTrue,
    );
  });

  testWidgets('letter tile uses the first grapheme and survives an empty '
      'name', (t) async {
    Future<void> pumpName(String n) =>
        t.pumpWidget(_host(ChannelPictureView(name: n, colorSeed: 'r1')));
    await pumpName('🏖️ beach');
    expect(find.text('🏖️'), findsOneWidget);
    await pumpName('trips');
    expect(find.text('T'), findsOneWidget);
    await pumpName('');
    expect(find.byType(Text), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('unknown and none pictures render the letter tile', (t) async {
    await t.pumpWidget(
      _host(
        const ChannelPictureView(
          name: 'trips',
          colorSeed: 'r1',
          picture: UnknownPicture({'type': 'future'}),
        ),
      ),
    );
    expect(find.text('T'), findsOneWidget);
    await t.pumpWidget(
      _host(
        const ChannelPictureView(
          name: 'trips',
          colorSeed: 'r1',
          picture: NoPicture(),
        ),
      ),
    );
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('letter colour is stable across a rename', (t) async {
    await t.pumpWidget(
      _host(const ChannelPictureView(name: 'trips', colorSeed: 'r1')),
    );
    final before = _tintOf(t);
    await t.pumpWidget(
      _host(const ChannelPictureView(name: 'holiday', colorSeed: 'r1')),
    );
    expect(_tintOf(t), before);
    expect(
      before,
      AppPalette.light.channelSwatches[channelColorFor('r1').index].tint,
    );
  });

  testWidgets('tiles are rounded squares, not circles', (t) async {
    await t.pumpWidget(
      _host(const ChannelPictureView(name: 'trips', colorSeed: 'r1')),
    );
    final clip = t.widget<ClipRRect>(
      find.descendant(
        of: find.byType(ChannelPictureView),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(14));
    expect(t.getSize(find.byType(ChannelPictureView)), const Size(52, 52));
  });

  for (final bad in ['not base64!!', '']) {
    testWidgets('a malformed thumbnail falls back to the letter tile '
        '("$bad")', (t) async {
      final room = Room(
        roomId: 'room-1',
        name: 'trips',
        members: const [],
        createdAt: DateTime(2026),
      );
      final desc = AttachmentDescriptor(
        blobKey: 'k',
        contentKeyB64: '',
        nonceB64: '',
        mime: 'image/jpeg',
        filename: 'p.jpg',
        size: 1,
        width: 512,
        height: 512,
        durationMs: null,
        thumbB64: bad,
      );
      await t.pumpWidget(
        _host(
          ChannelTile(room: room, selfUsername: 'me'),
          overrides: [
            currentChannelPictureProvider(
              'room-1',
            ).overrideWithValue(PhotoPicture(desc)),
            channelPhotoFileProvider('room-1').overrideWith((ref) => null),
          ],
        ),
      );
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.byType(Image), findsNothing);
      expect(find.text('T'), findsOneWidget);
    });
  }

  testWidgets('an undecodable photo falls back to the letter tile', (t) async {
    await t.pumpWidget(
      _host(
        ChannelPictureView(
          name: 'trips',
          colorSeed: 'r1',
          photo: MemoryImage(Uint8List.fromList(List.filled(32, 7))),
        ),
      ),
    );
    // The decode failure arrives on a real async tick; poll for the fallback.
    for (var i = 0; i < 50 && find.text('T').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
    }
    expect(find.text('T'), findsOneWidget);
  });
}
