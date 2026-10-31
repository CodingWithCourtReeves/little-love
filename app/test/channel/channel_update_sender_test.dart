import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/channel_update_sender.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_drain.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/wire/frames.dart' show Member;
import 'package:littlelove/wire/message.dart';

import '../outbox/memory_outbox_store.dart';

Future<DerivedIdentity> _id(int b) => derivedIdentityFromSigningSeedForTest(
  Uint8List.fromList(List.filled(32, b)),
);

Member _member(DerivedIdentity id, String username) => Member(
  username: username,
  ed25519PubBase64: base64.encode(id.ed25519PublicKey),
  x25519PubBase64: base64.encode(id.x25519PublicKey),
);

void main() {
  late DerivedIdentity me;
  late Room room;
  late MemoryOutboxStore store;

  setUp(() async {
    me = await _id(31);
    final partner = await _id(32);
    room = Room(
      roomId: 'chan1',
      name: 'Trips',
      members: [_member(me, 'court'), _member(partner, 'kaitlyn')],
      createdAt: DateTime.utc(2026, 6, 10),
    );
    store = MemoryOutboxStore();
  });

  ProviderContainer container({bool identityFails = false}) {
    final c = ProviderContainer(
      overrides: [
        currentIdentityProvider.overrideWith(
          (ref) => identityFails
              ? Future<DerivedIdentity>.error(StateError('no identity'))
              : Future.value(me),
        ),
        outboxStoreProvider.overrideWith((ref) => Future.value(store)),
        outboxDrainProvider.overrideWithValue(
          OutboxDrain(store: store, send: (_, _, _) {}),
        ),
        outboxIdGenProvider.overrideWithValue(() => 'cid-1'),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'choosing a symbol adds a sending channel row and enqueues one ciphertext per member',
    () async {
      final c = container();
      final ok = await c
          .read(channelUpdateSenderProvider)
          .applyChoice(
            room: room,
            selfUsername: 'court',
            choice: const ChooseSymbol(ChannelSymbol.heart, ChannelColor.rose),
          );
      expect(ok, ChannelUpdateResult.sent);
      final rows = c.read(messageStoreProvider('chan1'));
      expect(rows, hasLength(1));
      expect(rows.single.body, '');
      expect(rows.single.sendStatus, SendStatus.sending);
      final picture = rows.single.channelUpdate!.picture;
      expect(picture, isA<SymbolPicture>());
      final pending = await store.pending();
      expect(pending, hasLength(1));
      // Partner copy plus self copy.
      expect(pending.single.bodies, hasLength(2));
    },
  );

  test(
    'a photo with no connection returns offline and enqueues nothing',
    () async {
      final c = container();
      final result = await c
          .read(channelUpdateSenderProvider)
          .applyChoice(
            room: room,
            selfUsername: 'court',
            choice: ChoosePhoto(Uint8List.fromList([1, 2, 3])),
          );
      expect(result, ChannelUpdateResult.offline);
      expect(c.read(messageStoreProvider('chan1')), isEmpty);
      expect(await store.pending(), isEmpty);
    },
  );

  test(
    'a failure before enqueue removes the optimistic row and returns false',
    () async {
      final c = container(identityFails: true);
      final ok = await c
          .read(channelUpdateSenderProvider)
          .applyChoice(
            room: room,
            selfUsername: 'court',
            choice: const ChooseNone(),
          );
      expect(ok, ChannelUpdateResult.failed);
      expect(c.read(messageStoreProvider('chan1')), isEmpty);
      expect(await store.pending(), isEmpty);
    },
  );

  test('sendRenameLine enqueues a name-only channel_update', () async {
    final c = container();
    final ok = await c
        .read(channelUpdateSenderProvider)
        .sendRenameLine(room: room, selfUsername: 'court', name: 'Voyages');
    expect(ok, isTrue);
    final update = c.read(messageStoreProvider('chan1')).single.channelUpdate!;
    expect(update.name, 'Voyages');
    expect(update.picture, isNull);
    expect(await store.pending(), hasLength(1));
  });
}
