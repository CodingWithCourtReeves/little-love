import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'inbox_state.dart';
import 'read_state_provider.dart';

/// Select [roomId] as the active room and mark it read in one step. Use this
/// everywhere a room is opened (switcher tap, sidebar tap, auto-select on
/// create) so unread state stays consistent. Accepts any Riverpod reader
/// ([WidgetRef], [Ref], or [ProviderContainer]).
void selectAndMarkRead(dynamic reader, String roomId) {
  reader.read(inboxStateProvider.notifier).select(roomId);
  reader.read(readStateProvider.notifier).markRead(roomId);
}
