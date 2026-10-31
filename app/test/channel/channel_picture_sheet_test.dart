import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/attachment/square_image.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/channel_picture_sheet.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';

import '../support/widget_waits.dart';

final _room = Room(
  roomId: 'roomA',
  name: 'Trip',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'A', x25519PubBase64: 'B'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'C', x25519PubBase64: 'D'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

// image_picker_ios talks over Pigeon, not a MethodChannel, so the sheet takes
// the picker as an injected function.
class _Harness {
  _Harness(this.tester);
  final WidgetTester tester;
  ChannelPictureChoice? result;
  bool closed = false;
  Uint8List? pickerBytes;
  int pickerCalls = 0;

  Future<void> open({
    ChannelPicture? current,
    Room? room,
    Future<Uint8List> Function(Uint8List)? squarer,
  }) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showChannelPictureSheet(
                  context,
                  name: 'Trip',
                  colorSeed: 'roomA',
                  current: current,
                  room: room,
                  photoSource: (ImageSource s) async {
                    pickerCalls++;
                    return pickerBytes;
                  },
                  squarer: squarer ?? (b) async => squareJpeg(b),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await pumpUntilFound(tester, find.byKey(const Key('channel-picture-done')));
    await tester.pumpAndSettle(); // the slide-in animation
  }

  Future<void> tap(String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pump();
  }
}

void main() {
  testWidgets('Done returns the chosen symbol and colour', (tester) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-symbol-moon');
    await h.tap('channel-color-sky');
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    final r = h.result as ChooseSymbol;
    expect(r.symbol, ChannelSymbol.moon);
    expect(r.color, ChannelColor.sky);
  });

  testWidgets('Cancel returns null', (tester) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-symbol-moon');
    await h.tap('channel-picture-cancel');
    await pumpUntilTrue(tester, () => h.closed);
    expect(h.result, isNull);
  });

  testWidgets('Remove is shown only when a picture is set and returns '
      'ChooseNone', (tester) async {
    final h = _Harness(tester);
    await h.open();
    expect(find.byKey(const Key('channel-picture-remove')), findsNothing);
    await h.tap('channel-picture-cancel');
    await pumpUntilTrue(tester, () => h.closed);

    final h2 = _Harness(tester);
    await h2.open(current: const NoPicture());
    expect(find.byKey(const Key('channel-picture-remove')), findsNothing);
    await h2.tap('channel-picture-cancel');
    await pumpUntilTrue(tester, () => h2.closed);

    final h3 = _Harness(tester);
    await h3.open(
      current: const SymbolPicture(ChannelSymbol.leaf, ChannelColor.sage),
    );
    await h3.tap('channel-picture-remove');
    await pumpUntilTrue(tester, () => h3.closed);
    expect(h3.result, isA<ChooseNone>());
  });

  testWidgets('a cancelled photo picker leaves the sheet open and unchanged', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-picture-tab-photo');
    await h.tap('channel-picture-library');
    await pumpUntilTrue(tester, () => h.pickerCalls == 1);
    expect(find.byKey(const Key('channel-picture-done')), findsOneWidget);
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect(h.result, isNull);
  });

  testWidgets('a picked photo is squared and returned as ChoosePhoto', (
    tester,
  ) async {
    final h = _Harness(tester);
    h.pickerBytes = Uint8List.fromList([1, 2, 3]);
    await h.open(squarer: (b) async => Uint8List.fromList([9, 9]));
    await h.tap('channel-picture-tab-photo');
    await h.tap('channel-picture-camera');
    await pumpUntilTrue(tester, () => h.pickerCalls == 1);
    await tester.pump();
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect((h.result as ChoosePhoto).squaredJpeg, [9, 9]);
  });

  testWidgets('an undecodable photo shows a SnackBar and sends nothing', (
    tester,
  ) async {
    final h = _Harness(tester);
    h.pickerBytes = Uint8List.fromList([1, 2, 3]);
    await h.open();
    await h.tap('channel-picture-tab-photo');
    await h.tap('channel-picture-library');
    await pumpUntilFound(tester, find.text("Couldn't use that photo."));
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect(h.result, isNull);
  });

  testWidgets('the create-sheet variant hides pick from this chat', (
    tester,
  ) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-picture-tab-photo');
    expect(find.byKey(const Key('channel-picture-library')), findsOneWidget);
    expect(find.byKey(const Key('channel-picture-from-chat')), findsNothing);
    await h.tap('channel-picture-cancel');
    await pumpUntilTrue(tester, () => h.closed);

    final h2 = _Harness(tester);
    await h2.open(room: _room);
    await h2.tap('channel-picture-tab-photo');
    expect(find.byKey(const Key('channel-picture-from-chat')), findsOneWidget);
  });

  testWidgets('every control is at least 44 points tall', (tester) async {
    final h = _Harness(tester);
    await h.open(
      current: const SymbolPicture(ChannelSymbol.leaf, ChannelColor.sage),
    );
    for (final k in [
      'channel-picture-cancel',
      'channel-picture-done',
      'channel-picture-tab-photo',
      'channel-picture-tab-symbol',
      'channel-picture-remove',
      'channel-symbol-heart',
      'channel-color-rose',
    ]) {
      expect(
        tester.getSize(find.byKey(Key(k))).height,
        greaterThanOrEqualTo(44),
        reason: k,
      );
    }
    await h.tap('channel-picture-tab-photo');
    for (final k in ['channel-picture-library', 'channel-picture-camera']) {
      expect(
        tester.getSize(find.byKey(Key(k))).height,
        greaterThanOrEqualTo(44),
        reason: k,
      );
    }
  });

  testWidgets('a symbol picked then the Photo tab still returns the symbol on '
      'Done', (tester) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-symbol-star');
    await h.tap('channel-picture-tab-photo');
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect((h.result as ChooseSymbol).symbol, ChannelSymbol.star);
  });

  testWidgets('opening on a picture and tapping Done returns null', (
    tester,
  ) async {
    final symbol = _Harness(tester);
    await symbol.open(
      current: const SymbolPicture(ChannelSymbol.leaf, ChannelColor.sage),
    );
    await symbol.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => symbol.closed);
    expect(symbol.result, isNull);

    final photo = _Harness(tester);
    await photo.open(
      current: PhotoPicture(
        const AttachmentDescriptor(
          blobKey: 'b',
          contentKeyB64: 'k',
          nonceB64: 'n',
          mime: 'image/jpeg',
          filename: 'f.jpg',
          size: 1,
          width: 1,
          height: 1,
          durationMs: null,
          thumbB64: '',
        ),
      ),
    );
    await photo.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => photo.closed);
    expect(photo.result, isNull);
  });

  testWidgets('Done with nothing picked returns null', (tester) async {
    final h = _Harness(tester);
    await h.open();
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect(h.result, isNull);
  });

  testWidgets('Done is disabled while a photo is being prepared', (
    tester,
  ) async {
    final h = _Harness(tester);
    h.pickerBytes = Uint8List.fromList([1, 2, 3]);
    final gate = Completer<Uint8List>();
    await h.open(squarer: (_) => gate.future);
    await h.tap('channel-picture-tab-photo');
    await h.tap('channel-picture-library');
    await pumpUntilFound(tester, find.byKey(const Key('channel-picture-busy')));
    expect(find.text('Done'), findsNothing);
    await h.tap('channel-picture-done');
    expect(h.closed, isFalse);

    gate.complete(Uint8List.fromList([7]));
    await pumpUntilFound(tester, find.text('Done'));
    await h.tap('channel-picture-done');
    await pumpUntilTrue(tester, () => h.closed);
    expect((h.result as ChoosePhoto).squaredJpeg, [7]);
  });

  testWidgets('symbol cells, swatches and tabs expose button and selected '
      'semantics', (tester) async {
    final handle = tester.ensureSemantics();
    final h = _Harness(tester);
    await h.open();
    expect(
      tester.getSemantics(find.byKey(const Key('channel-symbol-heart'))),
      matchesSemantics(
        label: 'Heart',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
        isSelected: true,
        hasEnabledState: false,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('channel-symbol-moon'))),
      matchesSemantics(
        label: 'Moon',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    expect(find.bySemanticsLabel('Sage colour'), findsOneWidget);
    expect(find.bySemanticsLabel('Symbol'), findsOneWidget);
    handle.dispose();
  });
}
