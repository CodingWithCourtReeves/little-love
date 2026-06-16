import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../wire/frames.dart';
import '../wire/message.dart';
import 'inbox_state.dart';
import 'room.dart';

/// Two hardcoded rooms + a few synthetic messages, used **only** for the R3
/// manual smoke when the live pairing flow hasn't been exercised yet. Gated
/// by `--dart-define=LLOVE_FIXTURES=demo` (see main.dart). v0.3-shaped:
/// each room has a `members` list with the local user + one familiar.
final demoRooms = <Room>[
  Room(
    roomId: 'demo-room-kaitlyn',
    name: '',
    members: const [
      Member(
        username: 'court',
        ed25519PubBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        x25519PubBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=',
        isBot: false,
      ),
      Member(
        username: 'kaitlyn',
        ed25519PubBase64: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=',
        x25519PubBase64: 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDA=',
        isBot: false,
      ),
    ],
    createdAt: DateTime.utc(2026, 6, 1),
  ),
  Room(
    roomId: 'demo-room-sage',
    name: 'Sage',
    members: const [
      Member(
        username: 'court',
        ed25519PubBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        x25519PubBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=',
        isBot: false,
      ),
      Member(
        username: 'court-sage',
        ed25519PubBase64: 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEA=',
        x25519PubBase64: 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFA=',
        isBot: true,
        ownerUsername: 'court',
      ),
    ],
    createdAt: DateTime.utc(2026, 6, 5),
  ),
];

void seedDemoFixtures(ProviderContainer container) {
  container.read(inboxStateProvider.notifier).setRooms(demoRooms);
  container.read(messageStoreProvider('demo-room-kaitlyn').notifier).setAll([
    Msg(
      id: 'demo-1',
      from: 'kaitlyn',
      to: 'court',
      body: 'hey :)',
      ts: DateTime.utc(2026, 6, 9, 17, 0),
    ),
    Msg(
      id: 'demo-2',
      from: 'court',
      to: 'kaitlyn',
      body: 'miss you',
      ts: DateTime.utc(2026, 6, 9, 17, 1),
    ),
  ]);
  container.read(messageStoreProvider('demo-room-sage').notifier).setAll([
    Msg(
      id: 'demo-3',
      from: 'sage',
      to: 'court',
      body: 'one for the road',
      ts: DateTime.utc(2026, 6, 8, 12, 0),
    ),
  ]);
}
