import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/twilight.dart';
import 'inbox_state.dart';
import 'select_room.dart';

/// Compact icon rail at 600–799px widths (spec §6.1). One icon per room;
/// label appears as a tooltip. Each tile is ≥56×56 (well over the 44×44
/// floor required by spec §6.4).
class NavigationRailChrome extends ConsumerWidget {
  const NavigationRailChrome({super.key, this.username = ''});

  /// Authenticated user's username — used to derive a room's display label
  /// when [Room.name] is empty.
  final String username;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    if (inbox.rooms.isEmpty) {
      return const SizedBox(width: 56);
    }
    return Material(
      color: TwilightColors.bgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in inbox.rooms)
            _entry(
              context,
              ref,
              r.roomId,
              r.displayName(username),
              r.roomId == inbox.selectedRoomId,
            ),
        ],
      ),
    );
  }

  Widget _entry(
    BuildContext context,
    WidgetRef ref,
    String roomId,
    String label,
    bool selected,
  ) {
    return Tooltip(
      message: label,
      child: InkWell(
        key: Key('rail-room-$roomId'),
        onTap: () => selectAndMarkRead(ref, roomId),
        child: Container(
          width: 56,
          constraints: const BoxConstraints(minHeight: 56),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? TwilightColors.bgSurfaceAlt : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected
                    ? TwilightColors.accentUser
                    : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: CircleAvatar(
            radius: 16,
            backgroundColor: TwilightColors.accentPartner,
            child: Text(
              label.isEmpty ? '?' : label[0].toUpperCase(),
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
