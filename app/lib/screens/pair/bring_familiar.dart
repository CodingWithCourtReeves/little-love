import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pairing/pairing_transport.dart';
import '../../pairing/qr.dart';
import '../../theme/twilight.dart';
import '../../wire/frames.dart';

/// Mints a familiar-ownership invite the owner reads out to the familiar CLI
/// running on hardware they control. Modeled on `ShowInviteScreen` but drives
/// `createFamiliarInvite()` and uses familiar-flavored copy.
class BringFamiliarScreen extends ConsumerStatefulWidget {
  const BringFamiliarScreen({super.key});

  @override
  ConsumerState<BringFamiliarScreen> createState() =>
      _BringFamiliarScreenState();
}

class _BringFamiliarScreenState extends ConsumerState<BringFamiliarScreen> {
  Future<InviteCreatedFrame>? _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(pairingTransportProvider).createFamiliarInvite();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TwilightColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: TwilightColors.bgSurface,
        title: const Text('Bring in a familiar'),
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
                  style: const TextStyle(
                    color: TwilightColors.textPrimary,
                    fontFamily: 'Inter',
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              );
            }
            final invite = snap.data!;
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: Text(
                      'Run the familiar CLI on your own hardware and enter '
                      'this code to bring it into a private chat with you.',
                      style: TwilightType.lede,
                      textAlign: TextAlign.center,
                    ),
                  ),
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
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: invite.code)),
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
