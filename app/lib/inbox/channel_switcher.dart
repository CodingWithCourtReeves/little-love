import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_palette.dart';
import 'inbox_state.dart';
import 'read_state_provider.dart';
import 'room.dart';
import 'select_room.dart';

/// Header pill that shows the active room and opens a dropdown of all rooms.
/// Partner thread is pinned; named channels follow; unread rows are bold +
/// dotted. The "+ New channel" row's tap is delegated via [onNewChannel].
class ChannelSwitcher extends ConsumerWidget {
  const ChannelSwitcher({
    super.key,
    required this.selfUsername,
    this.onNewChannel,
  });

  final String selfUsername;
  final VoidCallback? onNewChannel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inbox = ref.watch(inboxStateProvider);
    Room? selected;
    for (final r in inbox.rooms) {
      if (r.roomId == inbox.selectedRoomId) {
        selected = r;
        break;
      }
    }

    final isPartner =
        selected != null && selected.shape(selfUsername) == RoomShape.partner;
    final label = selected?.displayName(selfUsername) ?? 'LittleLove';
    final unreadElsewhere = ref.watch(
      anyUnreadProvider(inbox.selectedRoomId ?? ''),
    );

    return InkWell(
      key: const Key('channel-switcher-pill'),
      borderRadius: BorderRadius.circular(999),
      onTap: () => _openSheet(context, ref),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 7, 12, 7),
        decoration: BoxDecoration(
          color: context.palette.bgSurfaceAlt,
          border: Border.all(color: context.palette.borderSoft),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isPartner)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '#',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: context.palette.textMuted,
                  ),
                ),
              ),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: context.palette.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (unreadElsewhere)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: context.palette.accentUser,
                  shape: BoxShape.circle,
                ),
              ),
            Text(
              '▾',
              style: TextStyle(color: context.palette.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final selfUsername = this.selfUsername;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.palette.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => Consumer(
        builder: (context, ref, _) {
          final inbox = ref.watch(inboxStateProvider);
          List<Room> bucket(RoomShape s) =>
              inbox.rooms.where((r) => r.shape(selfUsername) == s).toList()
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          final partners = bucket(RoomShape.partner);
          final channels = bucket(RoomShape.chat);

          Widget rowFor(Room r, {required bool partner}) {
            final unread = ref.watch(roomUnreadProvider(r.roomId));
            return ListTile(
              key: Key('switcher-row-${r.roomId}'),
              leading: Text(
                partner ? '' : '#',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: context.palette.textMuted,
                ),
              ),
              title: Text(
                r.displayName(selfUsername),
                style: TextStyle(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                  color: context.palette.textPrimary,
                ),
              ),
              trailing: unread
                  ? Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: context.palette.accentUser,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
              selected: inbox.selectedRoomId == r.roomId,
              onTap: () {
                selectAndMarkRead(ref, r.roomId);
                Navigator.of(sheetCtx).pop();
              },
            );
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (partners.isNotEmpty) ...[
                  const _SectionLabel('YOU & PARTNER'),
                  ...partners.map((r) => rowFor(r, partner: true)),
                ],
                if (channels.isNotEmpty) ...[
                  const _SectionLabel('CHANNELS'),
                  ...channels.map((r) => rowFor(r, partner: false)),
                ],
                Divider(height: 1, color: context.palette.borderSoft),
                ListTile(
                  key: const Key('switcher-new-channel'),
                  leading: Text(
                    '+',
                    style: TextStyle(
                      fontSize: 18,
                      color: context.palette.accentUser,
                    ),
                  ),
                  title: Text(
                    'New channel',
                    style: TextStyle(
                      color: context.palette.accentUser,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    onNewChannel?.call();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        letterSpacing: 2.0,
        color: context.palette.accentSage,
      ),
    ),
  );
}
