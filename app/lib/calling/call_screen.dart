import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_controller.dart';
import 'call_state.dart';

/// In-app call view. CallKit owns the system/lock-screen UI; this is the
/// foreground screen shown while a call is dialing/connecting/active, with a
/// status line, mute, and hang-up. Auto-pops when the call ends.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const CallScreen());

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  bool _muted = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(callControllerProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF1A1326),
      body: SafeArea(
        child: ValueListenableBuilder<CallState>(
          valueListenable: controller.state,
          builder: (context, state, _) {
            // Pop once the call has ended.
            if (state.phase == CallPhase.ended || state.phase == CallPhase.idle) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              });
            }
            return Column(
              children: [
                const Spacer(),
                const Icon(Icons.favorite, color: Colors.white70, size: 72),
                const SizedBox(height: 24),
                Text(
                  _statusLabel(state.phase),
                  style: const TextStyle(color: Colors.white, fontSize: 22),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CircleButton(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      color: Colors.white24,
                      onTap: () {
                        setState(() => _muted = !_muted);
                        controller.toggleMute(_muted);
                      },
                    ),
                    _CircleButton(
                      icon: Icons.call_end,
                      color: Colors.red,
                      onTap: () => controller.hangup(),
                    ),
                  ],
                ),
                const SizedBox(height: 48),
              ],
            );
          },
        ),
      ),
    );
  }

  String _statusLabel(CallPhase phase) => switch (phase) {
        CallPhase.dialing => 'Calling…',
        CallPhase.ringing => 'Incoming call…',
        CallPhase.connecting => 'Connecting…',
        CallPhase.active => 'Connected',
        _ => '',
      };
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 30),
      ),
    );
  }
}
