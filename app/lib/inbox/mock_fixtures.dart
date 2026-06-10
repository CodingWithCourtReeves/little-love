import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation/message_store.dart';
import '../wire/message.dart';
import 'inbox_state.dart';
import 'room.dart';

/// Two hardcoded rooms + a few synthetic messages, used **only** for the R3
/// manual smoke when WT-D's pairing flow hasn't landed yet. Gated by
/// `--dart-define=LLOVE_FIXTURES=demo` (see main.dart). The integration
/// session removes the gate.
final demoRooms = <Room>[
  Room(
    roomId: 'demo-room-kaitlyn',
    peerUsername: 'kaitlyn',
    peerEd25519PubBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    peerX25519PubBase64: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=',
    createdAt: DateTime.utc(2026, 6, 1),
  ),
  Room(
    roomId: 'demo-room-sage',
    peerUsername: 'sage',
    peerEd25519PubBase64: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=',
    peerX25519PubBase64: 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDA=',
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
