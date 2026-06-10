import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pairing/invite_create.dart';
import '../../pairing/pairing_transport.dart';
import '../../pairing/qr.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';

class ShowInviteScreen extends ConsumerStatefulWidget {
  const ShowInviteScreen({super.key});

  @override
  ConsumerState<ShowInviteScreen> createState() => _ShowInviteScreenState();
}

class _ShowInviteScreenState extends ConsumerState<ShowInviteScreen> {
  Future<InviteCreatedFrame>? _future;

  @override
  void initState() {
    super.initState();
    _future = createInvite(ref.read(pairingTransportProvider));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('Invite your partner'),
      ),
      body: Center(
        child: FutureBuilder<InviteCreatedFrame>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator();
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not create invite: ${snap.error}',
                  style: const TextStyle(color: TwilightColors.textPrimary),
                ),
              );
            }
            final invite = snap.data!;
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InviteQr(code: invite.code),
                  const SizedBox(height: 20),
                  SelectableText(
                    invite.code,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                      color: TwilightColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: invite.code),
                    ),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const Text('Copy code'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Expires ${invite.expiresAt.toLocal()}',
                    style: const TextStyle(
                      color: TwilightColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
