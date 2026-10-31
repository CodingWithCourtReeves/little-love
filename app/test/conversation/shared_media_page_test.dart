import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/shared_media_page.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/theme/app_palette.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/message.dart';

import '../support/widget_waits.dart';

Room _room() => Room(
  roomId: 'roomA',
  name: 'Trip',
  members: const [
    Member(username: 'court', ed25519PubBase64: 'A', x25519PubBase64: 'B'),
    Member(username: 'kaitlyn', ed25519PubBase64: 'C', x25519PubBase64: 'D'),
  ],
  createdAt: DateTime.utc(2026, 6, 10),
);

AttachmentDescriptor _d(String key, String mime) => AttachmentDescriptor(
  blobKey: key,
  contentKeyB64: 'k',
  nonceB64: 'n',
  mime: mime,
  filename: key,
  size: 10,
  width: 10,
  height: 10,
  durationMs: null,
  thumbB64: '',
);

Msg _msg(String id, AttachmentDescriptor d) => Msg(
  id: id,
  from: 'kaitlyn',
  to: 'court',
  body: '',
  ts: DateTime.utc(2026, 6, 10, 9),
  attachment: d,
);

void main() {
  testWidgets('pick mode shows photos only and pops the tapped descriptor', (
    tester,
  ) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final photo = _d('photo-1', 'image/jpeg');
    c.read(messageStoreProvider('roomA').notifier).setAll([
      _msg('1', photo),
      _msg('2', _d('video-1', 'video/mp4')),
      _msg('3', _d('voice-1', 'audio/mp4')),
    ]);
    AttachmentDescriptor? picked;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(AppPalette.light),
          home: Builder(
            builder: (context) => TextButton(
              key: const Key('open'),
              onPressed: () async => picked = await Navigator.of(
                context,
              ).push(SharedMediaPage.pickPhotoRoute(room: _room())),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await pumpUntilFound(tester, find.byKey(const Key('chat-info-media-0')));

    expect(find.byKey(const Key('shared-tabs')), findsNothing);
    expect(find.byType(SharedMediaTile), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);

    await tester.tap(find.byKey(const Key('chat-info-media-0')));
    await pumpUntilTrue(tester, () => picked != null);
    expect(picked!.blobKey, 'photo-1');
  });
}
