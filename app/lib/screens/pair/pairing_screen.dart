import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../identity/current_identity.dart';
import '../../pairing/bip39_invite.dart';
import '../../pairing/deep_link.dart';
import '../../pairing/invite_consume.dart';
import '../../pairing/invite_create.dart';
import '../../pairing/invite_link.dart';
import '../../pairing/pairing_transport.dart';
import '../../pairing/qr.dart';
import '../../theme/app_palette.dart';
import '../../wire/frames.dart';

/// The single symmetric pre-pairing surface. Shows your own roomless invite
/// (link + QR + 4 words) **and** a field to enter your partner's code. Whoever
/// enters the other's code first completes the handshake; the server creates
/// the couple room on consume and pushes it to both sides, at which point
/// HomeScreen leaves this empty state for the room list.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key, required this.selfUsername});

  final String selfUsername;

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  Future<InviteCreatedFrame>? _myInvite;
  final _enter = TextEditingController();
  String? _enterError;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _myInvite = createInvite(ref.read(pairingTransportProvider));
    // A pair link may have arrived (cold start) before this screen mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ref.read(pendingPairCodeProvider);
      if (pending != null && mounted && !_joining) {
        ref.read(pendingPairCodeProvider.notifier).state = null;
        _enter.text = pending;
        _join();
      }
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _enter.text.trim();
    setState(() {
      _enterError = null;
      _joining = true;
    });
    try {
      decodeInviteCode(code); // local shape check before the round-trip
    } on InviteCodeException {
      setState(() {
        _enterError = 'That doesn\'t look like a 4-word code.';
        _joining = false;
      });
      return;
    }
    try {
      final identity = await ref.read(currentIdentityProvider.future);
      final transport = ref.read(pairingTransportProvider);
      await consumeInvite(transport: transport, identity: identity, code: code);
      // Success: the InviteConsumed/RoomCreated frame lands the room in the
      // inbox via RoomMessageRouter; HomeScreen rebuilds and (single-room
      // auto-open) pushes the chat. Nothing more to do here.
    } on PairingTransportException catch (e) {
      setState(() {
        _enterError = e.code == 'AlreadyPaired'
            ? 'You\'re already paired.'
            : 'Could not pair: ${e.message.isEmpty ? e.code : e.message}';
        _joining = false;
      });
    } catch (e) {
      setState(() {
        _enterError = 'Could not pair: $e';
        _joining = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // A pair link arrived while this screen is on stage: prefill and auto-join.
    ref.listen<String?>(pendingPairCodeProvider, (_, code) {
      if (code == null) return;
      // Reset the one-shot command after this frame (Riverpod forbids mutating
      // a provider inside a listener that runs during build).
      Future.microtask(
        () => ref.read(pendingPairCodeProvider.notifier).state = null,
      );
      if (_joining) return;
      _enter.text = code;
      _join();
    });
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'PAIR WITH YOUR PARTNER',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 11,
                    letterSpacing: 2.4,
                    fontWeight: FontWeight.w500,
                    color: context.palette.accentSage,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Send them your code',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 26,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    color: context.palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                _MyInvite(future: _myInvite!),
                const SizedBox(height: 36),
                Divider(color: context.palette.borderSoft),
                const SizedBox(height: 24),
                Text(
                  '…or enter theirs',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: context.palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('pairing-enter-field'),
                  controller: _enter,
                  enabled: !_joining,
                  decoration: const InputDecoration(
                    labelText: 'four words separated by dashes',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('pairing-join-button'),
                  onPressed: _joining ? null : _join,
                  child: const Text('Join their chat'),
                ),
                if (_enterError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _enterError!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MyInvite extends StatelessWidget {
  const _MyInvite({required this.future});
  final Future<InviteCreatedFrame> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InviteCreatedFrame>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          );
        }
        if (snap.hasError) {
          final err = snap.error;
          final alreadyPaired =
              err is PairingTransportException && err.code == 'AlreadyPaired';
          return Text(
            alreadyPaired
                ? "You're already paired with a partner."
                : 'Could not create an invite: $err',
            style: TextStyle(color: context.palette.textPrimary),
            textAlign: TextAlign.center,
          );
        }
        final invite = snap.data!;
        final link = pairLink(invite.code);
        return Column(
          children: [
            InviteQr(code: invite.code),
            const SizedBox(height: 18),
            SelectableText(
              invite.code,
              key: const Key('pairing-code-text'),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 18,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: context.palette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              link,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: context.palette.textMuted,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: invite.code)),
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('Copy code'),
                ),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: link)),
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Copy link'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
