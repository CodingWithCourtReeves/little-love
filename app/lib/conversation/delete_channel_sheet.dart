import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../channel/channel_tile.dart';
import '../inbox/channel_deletion.dart';
import '../inbox/room.dart';
import '../theme/app_palette.dart';

/// Open the `Delete <channel>?` sheet. Delete stays disabled until the
/// channel's name is typed ([channelNameMatches]); then [onDelete] asks the
/// server and the sheet waits for its answer. On success the sheet closes
/// (the home screen then pops the chat and shows the toast); offline or a
/// failure keeps it open with a line saying so. Modelled on the New channel
/// sheet (`screens/create_chat/create_channel_sheet.dart`).
Future<void> showDeleteChannelSheet(
  BuildContext context, {
  required Room room,
  required String selfUsername,
  required Future<DeleteChannelOutcome> Function() onDelete,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.palette.bgCanvas,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
      ),
      child: _DeleteChannelSheet(
        room: room,
        selfUsername: selfUsername,
        onDelete: onDelete,
      ),
    ),
  );
}

class _DeleteChannelSheet extends StatefulWidget {
  const _DeleteChannelSheet({
    required this.room,
    required this.selfUsername,
    required this.onDelete,
  });
  final Room room;
  final String selfUsername;
  final Future<DeleteChannelOutcome> Function() onDelete;

  @override
  State<_DeleteChannelSheet> createState() => _DeleteChannelSheetState();
}

class _DeleteChannelSheetState extends State<_DeleteChannelSheet> {
  final _controller = TextEditingController();

  /// True while waiting for the server: the field locks and the button spins.
  bool _busy = false;

  /// Shown above the button after offline or a failure. In the sheet rather
  /// than a SnackBar, which would sit under this modal.
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _matches => channelNameMatches(_controller.text, widget.room.name);

  Future<void> _confirm() async {
    if (_busy || !_matches) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await widget.onDelete();
    if (!mounted) return;
    switch (outcome) {
      case DeleteChannelOutcome.deleted:
        Navigator.of(context).pop();
      case DeleteChannelOutcome.offline:
        setState(() {
          _busy = false;
          _error = 'You\'re offline. Connect to delete this channel.';
        });
      case DeleteChannelOutcome.failed:
        setState(() {
          _busy = false;
          _error = 'Couldn\'t delete the channel. Try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = widget.room.name;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: p.borderSoft,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Text(
              'Delete $name?',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 23,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This deletes the channel and all its messages for both of you. '
              'This can\'t be undone.',
              style: TextStyle(fontSize: 13, height: 1.45, color: p.textMuted),
            ),
            const SizedBox(height: 20),
            Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 13, color: p.textMuted),
                children: [
                  const TextSpan(text: 'Type '),
                  TextSpan(
                    text: name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  const TextSpan(text: ' to confirm'),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                ChannelTile(
                  room: widget.room,
                  selfUsername: widget.selfUsername,
                  size: 44,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('delete-channel-field'),
                    controller: _controller,
                    autofocus: true,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.none,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _confirm(),
                    decoration: const InputDecoration(
                      hintText: 'Channel name',
                      border: InputBorder.none,
                    ),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: p.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            Divider(color: p.borderSoft),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                key: const Key('delete-channel-error'),
                style: TextStyle(fontSize: 13, color: p.warningTone),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('delete-channel-confirm'),
              onPressed: (_matches && !_busy) ? _confirm : null,
              style: FilledButton.styleFrom(
                backgroundColor: p.destructiveFill,
                foregroundColor: p.onDestructiveFill,
                minimumSize: const Size.fromHeight(50),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: p.textMuted,
                      ),
                    )
                  : const Text('Delete channel'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('delete-channel-cancel'),
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                foregroundColor: p.accentUser,
                textStyle: const TextStyle(fontSize: 17),
              ),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
