import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../profile/avatar.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import 'call_controller.dart';
import 'call_state.dart';

/// App-root overlay that shows the in-app call UI on BOTH sides whenever a call
/// is live (dialing / connecting / active), so caller and callee see the same
/// screen. CallKit still owns the ring and the system/lock-screen/CarPlay UI;
/// this is the in-app view when you're looking at the phone.
class CallOverlay extends ConsumerWidget {
  const CallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(callControllerProvider);
    final profiles = ref.watch(profileStoreProvider);
    return ValueListenableBuilder<CallState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        final show =
            state.phase == CallPhase.dialing ||
            state.phase == CallPhase.connecting ||
            state.phase == CallPhase.active;
        if (!show) return const SizedBox.shrink();
        // Resolve the partner's display name + avatar from their synced profile,
        // falling back to the username / initials.
        final username = controller.peerName;
        final name = profiles.forUsername(username)?.displayName ?? username;
        return Positioned.fill(
          child: _CallView(
            controller: controller,
            state: state,
            name: name,
            avatarFile: profiles.avatarFileFor(username),
          ),
        );
      },
    );
  }
}

class _CallView extends StatefulWidget {
  const _CallView({
    required this.controller,
    required this.state,
    required this.name,
    required this.avatarFile,
  });
  final CallController controller;
  final CallState state;
  final String name;
  final File? avatarFile;

  @override
  State<_CallView> createState() => _CallViewState();
}

class _CallViewState extends State<_CallView>
    with SingleTickerProviderStateMixin {
  bool _muted = false;
  bool _speaker = false;
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  Timer? _ticker;
  DateTime? _connectedAt;
  Duration _elapsed = Duration.zero;

  @override
  void didUpdateWidget(covariant _CallView old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.state.phase == CallPhase.active && _ticker == null) {
      _connectedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _elapsed = DateTime.now().difference(_connectedAt!));
        }
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accentPartner;
    final name = widget.name;
    final active = widget.state.phase == CallPhase.active;

    return Material(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF211526), Color(0xFF15101D)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              // Breathing glow + avatar.
              AnimatedBuilder(
                animation: _breath,
                builder: (context, child) {
                  final t = active ? 0.0 : _breath.value;
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.20 + 0.22 * t),
                          blurRadius: 48 + 26 * t,
                          spreadRadius: 6 + 10 * t,
                        ),
                      ],
                    ),
                    child: child,
                  );
                },
                child: Avatar(
                  seedText: name,
                  imageFile: widget.avatarFile,
                  radius: 66,
                ),
              ),
              const SizedBox(height: 34),
              Text(
                name,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 30,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.6,
                  color: Color(0xFFF3ECF1),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _statusLabel(),
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  letterSpacing: 0.3,
                  color: const Color(0xFFF3ECF1).withValues(alpha: 0.55),
                ),
              ),
              const Spacer(flex: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlButton(
                    icon: _muted ? Icons.mic_off : Icons.mic,
                    label: 'mute',
                    active: _muted,
                    accent: accent,
                    onTap: () {
                      setState(() => _muted = !_muted);
                      widget.controller.toggleMute(_muted);
                    },
                  ),
                  const SizedBox(width: 26),
                  _ControlButton(
                    icon: _speaker ? Icons.volume_up : Icons.hearing,
                    label: _speaker ? 'speaker' : 'audio',
                    active: _speaker,
                    accent: accent,
                    onTap: () async {
                      setState(() => _speaker = !_speaker);
                      await Helper.setSpeakerphoneOn(_speaker);
                    },
                  ),
                  const SizedBox(width: 26),
                  _ControlButton(
                    icon: Icons.call_end,
                    label: 'end',
                    accent: accent,
                    danger: true,
                    onTap: () => widget.controller.hangup(),
                  ),
                ],
              ),
              const Spacer(flex: 1),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel() {
    switch (widget.state.phase) {
      case CallPhase.dialing:
        return 'Calling…';
      case CallPhase.connecting:
        return 'Connecting…';
      case CallPhase.active:
        final m = _elapsed.inMinutes.toString().padLeft(2, '0');
        final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
        return '$m:$s';
      default:
        return '';
    }
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool active;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final size = danger ? 72.0 : 64.0;
    final fill = danger
        ? const Color(0xFFC0455B)
        : active
        ? accent
        : Colors.white.withValues(alpha: 0.10);
    final border = active || danger
        ? Colors.transparent
        : Colors.white.withValues(alpha: 0.16);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
              border: Border.all(color: border, width: 1),
            ),
            child: Icon(icon, color: Colors.white, size: danger ? 32 : 27),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            letterSpacing: 0.4,
            color: const Color(0xFFF3ECF1).withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}
