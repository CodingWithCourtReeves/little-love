import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_controller.dart';
import 'call_state.dart';

/// App-root overlay that shows the in-app call UI on BOTH sides whenever a call
/// is live (dialing / connecting / active), so the caller and callee see the
/// same screen. CallKit still owns the ring and the system/lock-screen/CarPlay
/// UI; this is the in-app view when you're looking at the phone.
///
/// Mounted once via `MaterialApp.builder` so it floats above all routes.
class CallOverlay extends ConsumerWidget {
  const CallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(callControllerProvider);
    return ValueListenableBuilder<CallState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        // Ringing (incoming, pre-accept) is owned by CallKit's native screen;
        // we only take over once the user is in the call.
        final show = state.phase == CallPhase.dialing ||
            state.phase == CallPhase.connecting ||
            state.phase == CallPhase.active;
        if (!show) return const SizedBox.shrink();
        return Positioned.fill(child: _CallView(controller: controller, state: state));
      },
    );
  }
}

class _CallView extends StatefulWidget {
  const _CallView({required this.controller, required this.state});
  final CallController controller;
  final CallState state;

  @override
  State<_CallView> createState() => _CallViewState();
}

class _CallViewState extends State<_CallView> {
  bool _muted = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1326),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const Icon(Icons.favorite, color: Colors.white70, size: 72),
            const SizedBox(height: 24),
            Text(
              _statusLabel(widget.state.phase),
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
                    widget.controller.toggleMute(_muted);
                  },
                ),
                _CircleButton(
                  icon: Icons.call_end,
                  color: Colors.red,
                  onTap: () => widget.controller.hangup(),
                ),
              ],
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  String _statusLabel(CallPhase phase) => switch (phase) {
        CallPhase.dialing => 'Calling…',
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
