import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/keypair.dart';
import '../../identity/providers.dart';
import '../../inbox/inbox_state.dart';
import '../../inbox/room.dart';
import '../../pairing/bip39_invite.dart';
import '../../pairing/invite_consume.dart';
import '../../pairing/pairing_transport.dart';
import '../../theme/twilight.dart';
import '../../wire/rest_client.dart';

/// Receiver-side pairing screen: code → preview → confirm → consume → add Room.
class EnterCodeScreen extends ConsumerStatefulWidget {
  const EnterCodeScreen({super.key, required this.identity});

  /// The signed-in user's derived identity (used to sign the §8.5.1 input).
  /// Caller supplies because identity derivation requires unlocking the
  /// keystore, which is the routing-layer's responsibility.
  final DerivedIdentity identity;

  @override
  ConsumerState<EnterCodeScreen> createState() => _EnterCodeScreenState();
}

class _EnterCodeScreenState extends ConsumerState<EnterCodeScreen> {
  final _controller = TextEditingController();
  String? _error;
  InvitePreviewResponse? _preview;
  String? _pendingCode;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _doPreview() async {
    final code = _controller.text.trim();
    setState(() {
      _error = null;
      _preview = null;
      _busy = true;
    });
    try {
      decodeInviteCode(code); // fail fast on malformed codes
    } on InviteCodeException {
      setState(() {
        _error = 'Invalid invite code';
        _busy = false;
      });
      return;
    }
    try {
      final rest = ref.read(restClientProvider);
      final preview = await rest.previewInvite(code);
      setState(() {
        _preview = preview;
        _pendingCode = code;
        _busy = false;
      });
    } on InviteNotFoundException {
      setState(() {
        _error = 'No such invite — double-check the code.';
        _busy = false;
      });
    } on InviteGoneException {
      setState(() {
        _error = 'That invite has expired or already been used.';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not check that code: $e';
        _busy = false;
      });
    }
  }

  Future<void> _doConfirm() async {
    final preview = _preview;
    final code = _pendingCode;
    if (preview == null || code == null) return;
    setState(() => _busy = true);
    try {
      final transport = ref.read(pairingTransportProvider);
      final consumed = await consumeInvite(
        transport: transport,
        identity: widget.identity,
        code: code,
      );
      final room = Room(
        roomId: consumed.peer.roomId,
        peerUsername: consumed.peer.peerUsername,
        peerEd25519PubBase64: consumed.peer.peerEd25519PubBase64,
        peerX25519PubBase64: consumed.peer.peerX25519PubBase64,
        createdAt: DateTime.now().toUtc(),
      );
      ref.read(inboxStateProvider.notifier).setRooms([room]);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = 'Could not pair: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('Enter invite code'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('enter-code-field'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'four words separated by dashes',
                border: OutlineInputBorder(),
              ),
              enabled: !_busy && preview == null,
            ),
            const SizedBox(height: 16),
            if (preview == null)
              FilledButton(
                key: const Key('preview-button'),
                onPressed: _busy ? null : _doPreview,
                child: const Text('Look up'),
              ),
            if (preview != null) ...[
              Text(
                'Pair with @${preview.inviterUsername}?',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  color: TwilightColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('confirm-pair-button'),
                onPressed: _busy ? null : _doConfirm,
                child: const Text('Confirm'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }
}
