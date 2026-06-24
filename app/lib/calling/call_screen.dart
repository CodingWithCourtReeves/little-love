import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
          child: state.isVideo
              ? _VideoCallView(
                  controller: controller,
                  state: state,
                  name: name,
                  avatarFile: profiles.avatarFileFor(username),
                )
              : _CallView(
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

/// The in-app video-call view: the partner's camera fills the screen with a
/// draggable self-preview in the corner. Falls back to the breathing avatar
/// (same palette as the voice screen) whenever the remote video isn't flowing
/// yet — dialing, connecting, or the partner has their camera off.
class _VideoCallView extends StatefulWidget {
  const _VideoCallView({
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
  State<_VideoCallView> createState() => _VideoCallViewState();
}

class _VideoCallViewState extends State<_VideoCallView> {
  final RTCVideoRenderer _local = RTCVideoRenderer();
  final RTCVideoRenderer _remote = RTCVideoRenderer();
  bool _ready = false;
  StreamSubscription<MediaStream>? _remoteSub;
  MediaStream? _boundLocal;
  MediaStream? _boundRemote;

  bool _muted = false;
  bool _cameraOn = true;
  bool _speaker = true; // video calls default to hands-free (speaker)

  // Self-preview position (top-right by default); dragged within the screen.
  Offset? _pipPos;

  Timer? _ticker;
  DateTime? _connectedAt;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _cameraOn = widget.controller.hasLocalVideo;
    _init();
  }

  Future<void> _init() async {
    await _local.initialize();
    await _remote.initialize();
    if (!mounted) return;
    setState(() => _ready = true);
    _bindStreams();
    _remoteSub = widget.controller.onRemoteStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _boundRemote = s;
        _remote.srcObject = s;
      });
    });
    // Speaker routing is handled by the controller on the Connected transition
    // (CallKit owns the audio session until then).
    _syncTimer();
  }

  void _bindStreams() {
    final local = widget.controller.localStream;
    if (local != _boundLocal) {
      _boundLocal = local;
      _local.srcObject = local;
      _cameraOn = widget.controller.hasLocalVideo;
    }
    final remote = widget.controller.remoteStream;
    if (remote != _boundRemote) {
      _boundRemote = remote;
      _remote.srcObject = remote;
    }
  }

  @override
  void didUpdateWidget(covariant _VideoCallView old) {
    super.didUpdateWidget(old);
    if (_ready) _bindStreams();
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

  void _applyAudioRoute() {
    unawaited(Helper.setSpeakerphoneOn(_speaker));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _remoteSub?.cancel();
    _local.srcObject = null;
    _remote.srcObject = null;
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  bool get _remoteHasVideo {
    final s = _remote.srcObject;
    return s != null && s.getVideoTracks().isNotEmpty;
  }

  bool get _showSelfPreview => _cameraOn && widget.controller.hasLocalVideo;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accentPartner;
    return Material(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const pipW = 108.0;
          const pipH = 156.0;
          // Default the preview to the top-right inside the safe-ish margin.
          final pad = MediaQuery.of(context).padding;
          final pip =
              _pipPos ?? Offset(constraints.maxWidth - pipW - 16, pad.top + 12);
          return Stack(
            fit: StackFit.expand,
            children: [
              // Remote video (or avatar fallback while it isn't flowing).
              if (_ready && _remoteHasVideo)
                RTCVideoView(
                  _remote,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              else
                _AvatarBackdrop(
                  name: widget.name,
                  avatarFile: widget.avatarFile,
                  accent: accent,
                ),

              // Debug stats readout (TX/RX resolution · fps · bitrate · limit).
              // Debug builds only — gated out of release.
              if (kDebugMode)
                Positioned(
                  top: pad.top + 40,
                  left: 12,
                  right: 12,
                  child: ValueListenableBuilder<String>(
                    valueListenable: widget.controller.debugStats,
                    builder: (context, line, _) {
                      if (line.isEmpty) return const SizedBox.shrink();
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            line,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Color(0xFFB8F0C0),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              // Status line (Calling… / Connecting… / mm:ss) along the top.
              Positioned(
                top: pad.top + 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    _statusLabel(),
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 15,
                      letterSpacing: 0.3,
                      color: const Color(0xFFF3ECF1).withValues(alpha: 0.85),
                      shadows: const [
                        Shadow(blurRadius: 8, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),

              // Draggable self-preview.
              if (_ready)
                Positioned(
                  left: pip.dx.clamp(8.0, constraints.maxWidth - pipW - 8),
                  top: pip.dy.clamp(
                    pad.top + 8,
                    constraints.maxHeight - pipH - 120,
                  ),
                  width: pipW,
                  height: pipH,
                  child: GestureDetector(
                    onPanUpdate: (d) => setState(() => _pipPos = pip + d.delta),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: _showSelfPreview
                          ? RTCVideoView(
                              _local,
                              mirror: true,
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover,
                            )
                          : Container(
                              color: Colors.black.withValues(alpha: 0.55),
                              child: const Icon(
                                Icons.videocam_off,
                                color: Colors.white70,
                                size: 30,
                              ),
                            ),
                    ),
                  ),
                ),

              // Controls.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Row(
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
                        const SizedBox(width: 14),
                        _ControlButton(
                          icon: _speaker ? Icons.volume_up : Icons.hearing,
                          label: _speaker ? 'speaker' : 'earpiece',
                          active: _speaker,
                          accent: accent,
                          onTap: () {
                            setState(() => _speaker = !_speaker);
                            _applyAudioRoute();
                          },
                        ),
                        const SizedBox(width: 14),
                        _ControlButton(
                          icon: _cameraOn ? Icons.videocam : Icons.videocam_off,
                          label: 'camera',
                          active: !_cameraOn,
                          accent: accent,
                          onTap: () {
                            setState(() => _cameraOn = !_cameraOn);
                            widget.controller.setCameraEnabled(_cameraOn);
                          },
                        ),
                        const SizedBox(width: 14),
                        _ControlButton(
                          icon: Icons.cameraswitch,
                          label: 'flip',
                          accent: accent,
                          onTap: () => widget.controller.switchCamera(),
                        ),
                        const SizedBox(width: 14),
                        _ControlButton(
                          icon: Icons.call_end,
                          label: 'end',
                          accent: accent,
                          danger: true,
                          onTap: () => widget.controller.hangup(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
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

/// The gradient + breathing-avatar backdrop shown behind a video call until the
/// partner's camera is on screen (matches the voice-call palette).
class _AvatarBackdrop extends StatelessWidget {
  const _AvatarBackdrop({
    required this.name,
    required this.avatarFile,
    required this.accent,
  });
  final String name;
  final File? avatarFile;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF211526), Color(0xFF15101D)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.24),
                    blurRadius: 56,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: Avatar(seedText: name, imageFile: avatarFile, radius: 60),
            ),
            const SizedBox(height: 28),
            Text(
              name,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 28,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.6,
                color: Color(0xFFF3ECF1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
