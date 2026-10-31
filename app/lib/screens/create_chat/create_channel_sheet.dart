import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../channel/channel_picture.dart';
import '../../channel/channel_picture_sheet.dart';
import '../../channel/channel_tile.dart';
import '../../channel/pending_channel_actions.dart';
import '../../theme/app_palette.dart';
import '../../wire/frames.dart';
import '../../wire/live_connection.dart';

/// Normalize a free-text channel name to lowercase-with-dashes: lowercase,
/// non-alphanumeric runs become single dashes, leading/trailing dashes
/// trimmed. Pure + tested.
String formatChannelName(String input) {
  final lowered = input.toLowerCase();
  final dashed = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  return dashed.replaceAll(RegExp(r'^-+|-+$'), '');
}

/// Open the create-channel bottom sheet. Partner membership is implied
/// (`inviteHumanPartner: true`); the server adds the already-paired partner
/// directly with no pending invite.
Future<void> showCreateChannelSheet(BuildContext context, WidgetRef ref) {
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
      child: const _CreateChannelSheet(),
    ),
  );
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet();
  @override
  ConsumerState<_CreateChannelSheet> createState() =>
      _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _submitting = false;
  ChannelPictureChoice? _choice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _formatted => formatChannelName(_controller.text);

  Future<void> _create() async {
    if (_submitting) return;
    final name = _formatted;
    if (name.isEmpty) return;
    // ref.read(liveConnectionProvider).asData?.value gives the LiveConnection.
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected — try again in a moment.')),
      );
      return;
    }
    setState(() => _submitting = true);
    final choice = _choice;
    if (choice != null) {
      ref.read(pendingChannelActionsProvider).expectCreated(name, choice);
    }
    conn.send(CreateRoomFrame(name: name, inviteHumanPartner: true).toJson());
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickPicture() async {
    final choice = _choice;
    final choice2 = await showChannelPictureSheet(
      context,
      name: _formatted,
      colorSeed: _formatted,
      current: choice is ChooseSymbol
          ? SymbolPicture(choice.symbol, choice.color)
          : null,
      currentPhoto: choice is ChoosePhoto
          ? MemoryImage(choice.squaredJpeg)
          : null,
    );
    if (!mounted || choice2 == null) return;
    setState(() => _choice = choice2 is ChooseNone ? null : choice2);
  }

  Widget _pictureTile(BuildContext context) {
    final p = context.palette;
    const size = 44.0;
    final radius = BorderRadius.circular(size * 14 / 52);
    final choice = _choice;
    final name = _formatted;
    final Widget tile;
    if (choice is ChooseSymbol) {
      tile = ChannelPictureView(
        name: name,
        colorSeed: name,
        picture: SymbolPicture(choice.symbol, choice.color),
        size: size,
      );
    } else if (choice is ChoosePhoto) {
      tile = ChannelPictureView(
        name: name,
        colorSeed: name,
        photo: MemoryImage(choice.squaredJpeg),
        size: size,
      );
    } else {
      // Neutral, so the tile does not change colour once the room has an id.
      tile = Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: p.bgSurfaceAlt, borderRadius: radius),
        child: name.isEmpty
            ? Icon(Icons.photo_camera_outlined, size: 20, color: p.textMuted)
            : Text(
                name.characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: p.accentUser,
                ),
              ),
      );
    }
    return Semantics(
      button: true,
      label: 'Channel picture',
      excludeSemantics: true,
      child: GestureDetector(
        key: const Key('channel-name-picture'),
        behavior: HitTestBehavior.opaque,
        onTap: _pickPicture,
        child: SizedBox(width: size, height: size, child: tile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _formatted.isEmpty ? 'channel' : _formatted;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
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
                  color: context.palette.borderSoft,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            Text(
              'New channel',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 23,
                color: context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A topic room just for the two of you.',
              style: TextStyle(fontSize: 13, color: context.palette.textMuted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _pictureTile(context),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('channel-name-field'),
                    controller: _controller,
                    focusNode: _focus,
                    autofocus: true,
                    inputFormatters: [LengthLimitingTextInputFormatter(64)],
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _create(),
                    decoration: const InputDecoration(
                      hintText: 'date-ideas',
                      border: InputBorder.none,
                    ),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: context.palette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            Divider(color: context.palette.borderSoft),
            Text(
              'Preview:  #$preview',
              key: const Key('channel-preview'),
              style: TextStyle(fontSize: 12, color: context.palette.textMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('create-channel-button'),
              onPressed: (_formatted.isEmpty || _submitting) ? null : _create,
              style: FilledButton.styleFrom(
                backgroundColor: context.palette.accentUser,
                minimumSize: const Size.fromHeight(50),
              ),
              child: Text('Create #$preview'),
            ),
          ],
        ),
      ),
    );
  }
}
