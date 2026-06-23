import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/chat_info_page.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';
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

const _image = AttachmentDescriptor(
  blobKey: 'img-1',
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

final _voice = AttachmentDescriptor(
  blobKey: 'voice-1',
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

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: MaterialApp(
    theme: buildAppTheme(AppPalette.light),
    home: ChatInfoPage(room: _room(), selfUsername: 'court'),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Voice tab lists audio; Media grid excludes audio', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(messageStoreProvider('roomA').notifier).setAll([
      Msg(
        id: '1',
        from: 'court',
        to: 'kaitlyn',
        body: '',
        ts: DateTime.utc(2026, 6, 10, 9),
        attachment: _image,
      ),
      Msg(
        id: '2',
        from: 'kaitlyn',
        to: 'court',
        body: '',
        ts: DateTime.utc(2026, 6, 10, 10),
        attachment: _voice,
      ),
    ]);
    await tester.pumpWidget(_app(c));
    await tester.pump();

    // Media grid shows only the image (audio excluded): one tile, no second.
    expect(find.byKey(const Key('chat-info-media-0')), findsOneWidget);
    expect(find.byKey(const Key('chat-info-media-1')), findsNothing);

    // Voice tab lists the one voice memo.
    await tester.tap(find.text('Voice'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-info-voice-0')), findsOneWidget);
    expect(find.byKey(const Key('audio-play')), findsOneWidget);
  });
}
