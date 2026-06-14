import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inbox/owned_bots_provider.dart';
import '../../theme/twilight.dart';
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
    backgroundColor: TwilightColors.bgCanvas,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
      child: const _CreateChannelSheet(),
    ),
  );
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet();
  @override
  ConsumerState<_CreateChannelSheet> createState() => _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _selectedBots = <String>{};
  bool _submitting = false;

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
    // Mirror create_chat_pick_screen.dart's exact mechanism:
    // ref.read(liveConnectionProvider).asData?.value gives the LiveConnection.
    final conn = ref.read(liveConnectionProvider).asData?.value;
    if (conn == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected — try again in a moment.')),
      );
      return;
    }
    final bots = ref.read(ownedBotsProvider);
    final botAccountIds = <int>[
      for (final b in bots)
        if (_selectedBots.contains(b.username) && b.accountId != null)
          b.accountId!,
    ];
    setState(() => _submitting = true);
    // Mirror create_chat_pick_screen.dart: conn.send(Frame.toJson())
    conn.send(
      CreateRoomFrame(
        name: name,
        botAccountIds: botAccountIds,
        inviteHumanPartner: true,
      ).toJson(),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bots = ref.watch(ownedBotsProvider);
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
                    color: TwilightColors.borderSoft,
                    borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const Text(
              'New channel',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 23,
                  color: TwilightColors.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              'A topic room just for the two of you. Add a familiar to listen in.',
              style: TextStyle(fontSize: 13, color: TwilightColors.textMuted),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text(
                  '#',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: TwilightColors.textMuted),
                ),
                const SizedBox(width: 6),
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
                        hintText: 'date-ideas', border: InputBorder.none),
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: TwilightColors.textPrimary),
                  ),
                ),
              ],
            ),
            const Divider(color: TwilightColors.borderSoft),
            Text(
              'Preview:  #$preview',
              key: const Key('channel-preview'),
              style: const TextStyle(
                  fontSize: 12, color: TwilightColors.textMuted),
            ),
            const SizedBox(height: 16),
            if (bots.isNotEmpty) ...[
              const Text(
                'ADD A FAMILIAR · OPTIONAL',
                style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.8,
                    color: TwilightColors.accentFamiliar),
              ),
              const SizedBox(height: 8),
              for (final b in bots)
                CheckboxListTile(
                  key: Key('channel-familiar-${b.username}'),
                  value: _selectedBots.contains(b.username),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedBots.add(b.username);
                    } else {
                      _selectedBots.remove(b.username);
                    }
                  }),
                  title: Text(b.username),
                  controlAffinity: ListTileControlAffinity.trailing,
                  activeColor: TwilightColors.accentUser,
                ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              key: const Key('create-channel-button'),
              onPressed: (_formatted.isEmpty || _submitting) ? null : _create,
              style: FilledButton.styleFrom(
                backgroundColor: TwilightColors.accentUser,
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
