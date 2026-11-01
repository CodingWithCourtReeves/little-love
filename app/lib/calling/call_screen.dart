import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        if (!state.showsCallScreen) return const SizedBox.shrink();
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
    // Large in portrait; shrinks so the name and controls still fit in
    // landscape (about 375pt tall on the smaller phones).
    final avatarRadius = ((MediaQuery.sizeOf(context).height - 340) / 2).clamp(
      40.0,
      100.0,
    );

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
              const Spacer(flex: 2),
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
                  radius: avatarRadius,
                ),
              ),
              const Spacer(flex: 3),
              // Name and status sit just above the controls, End in the middle.
              _CallTitle(name: name, status: _statusLabel()),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlButton(
                    icon: Icons.volume_up,
                    label: 'speaker',
                    active: _speaker,
                    toggle: true,
                    accent: accent,
                    onTap: () async {
                      setState(() => _speaker = !_speaker);
                      await Helper.setSpeakerphoneOn(_speaker);
                    },
                  ),
                  const SizedBox(width: 22),
                  _ControlButton(
                    icon: Icons.call_end,
                    label: 'end',
                    accent: accent,
                    danger: true,
                    onTap: () => widget.controller.hangup(),
                  ),
                  const SizedBox(width: 22),
                  _ControlButton(
                    icon: _muted ? Icons.mic_off : Icons.mic,
                    label: 'mute',
                    active: _muted,
                    toggle: true,
                    accent: accent,
                    onTap: () {
                      setState(() => _muted = !_muted);
                      widget.controller.toggleMute(_muted);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 26),
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
    this.onVideo = false,
    this.toggle = false,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool active;
  final bool danger;

  /// Drawn over the partner's camera: a darker fill and a shadowed label, so
  /// both read on any picture. Slightly smaller, to fit five in a row.
  final bool onVideo;

  /// An on/off control (speaker, mute, camera): VoiceOver reads [active] as
  /// its state, since the label stays the same either way.
  final bool toggle;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final size = danger ? 76.0 : (onVideo ? 56.0 : 64.0);
    final fill = danger
        ? const Color(0xFFC0455B)
        : active
        ? accent
        : onVideo
        ? const Color(0xFF15101D).withValues(alpha: 0.45)
        : Colors.white.withValues(alpha: 0.10);
    final border = active || danger
        ? Colors.transparent
        : Colors.white.withValues(alpha: 0.16);
    return Semantics(
      button: true,
      label: label,
      toggled: toggle ? active : null,
      excludeSemantics: true,
      child: Column(
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
              child: Icon(
                icon,
                color: iconColor,
                size: danger ? 34 : (onVideo ? 24 : 27),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              letterSpacing: 0.4,
              color: const Color(
                0xFFF3ECF1,
              ).withValues(alpha: onVideo ? 0.9 : 0.6),
              shadows: onVideo
                  ? const [Shadow(blurRadius: 6, color: Colors.black54)]
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The partner's name with the call status (Calling…, Connecting…, mm:ss)
/// under it, set just above the controls.
class _CallTitle extends StatelessWidget {
  const _CallTitle({
    required this.name,
    required this.status,
    this.onVideo = false,
  });

  final String name;
  final String status;
  final bool onVideo;

  @override
  Widget build(BuildContext context) {
    final shadows = onVideo
        ? const [Shadow(blurRadius: 8, color: Colors.black54)]
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: onVideo ? 22 : 26,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.5,
              color: const Color(0xFFF3ECF1),
              shadows: shadows,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            status,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              letterSpacing: 0.3,
              color: const Color(
                0xFFF3ECF1,
              ).withValues(alpha: onVideo ? 0.9 : 0.6),
              shadows: shadows,
            ),
          ),
        ],
      ),
    );
  }
}

/// Height kept clear along the bottom of a video call for the partner's name
/// and the control row.
const double _videoControlsReserve = 240;

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

  // Immersive (full-screen) mode: tap the video to hide the controls + status;
  // they auto-hide after a few seconds of an active call. Privacy banners and
  // the self-preview stay visible.
  bool _controlsShown = true;
  Timer? _hideTimer;

  // Self full-screen: tap your preview to swap it into the main view (the
  // partner moves to the small tile). Pinch then drives the real camera zoom, so
  // the partner sees it too — handy for showing things with the back camera.
  bool _selfMain = false;
  double _camZoom = 1.0;
  double _zoomBase = 1.0;
  static const double _maxCamZoom = 8.0;

  // Emoji reactions floating up the screen.
  final List<Widget> _hearts = <Widget>[];
  StreamSubscription<String>? _reactionSub;
  final Random _rng = Random();

  // Self-preview position (top-right by default); dragged within the screen.
  Offset? _pipPos;

  // Pinch-to-zoom / pan transform for the remote video (display-side only —
  // doesn't change what's sent). Double-tap resets to fit.
  final TransformationController _zoom = TransformationController();

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
    _reactionSub = widget.controller.onReaction.listen(_spawnHeart);
    _syncTimer();
  }

  /// Float a heart up the screen and buzz a haptic (for sent and received).
  void _spawnHeart(String emoji) {
    HapticFeedback.lightImpact();
    final key = UniqueKey();
    setState(() {
      _hearts.add(
        _FloatingHeart(
          key: key,
          emoji: emoji,
          startX: (_rng.nextDouble() * 1.2) - 0.6,
          drift: (_rng.nextDouble() * 0.5) - 0.25,
          onDone: () {
            if (mounted) {
              setState(() => _hearts.removeWhere((w) => w.key == key));
            }
          },
        ),
      );
    });
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
      _scheduleHide();
    }
  }

  void _applyAudioRoute() {
    // Native path (not Helper.setSpeakerphoneOn): on iOS the plugin's speaker
    // override is silently reverted to the earpiece seconds later (flutter-webrtc
    // #1098/#1987). The controller's native side re-asserts it reactively.
    widget.controller.setSpeakerPreferred(_speaker);
  }

  /// Toggle the controls; reaching out shows them and restarts the auto-hide.
  void _toggleControls() {
    setState(() => _controlsShown = !_controlsShown);
    if (_controlsShown) _scheduleHide();
  }

  /// Auto-hide the controls a few seconds into an active call (no-op otherwise,
  /// so they stay put while dialing / connecting).
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (widget.state.phase != CallPhase.active) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsShown = false);
    });
  }

  /// Swap the main view between the partner (default) and your own camera.
  void _swapMainPip() => setState(() => _selfMain = !_selfMain);

  // Camera-zoom gesture (only while your own camera is the main view).
  void _onZoomStart(ScaleStartDetails _) => _zoomBase = _camZoom;

  void _onZoomUpdate(ScaleUpdateDetails d) {
    final z = (_zoomBase * d.scale).clamp(1.0, _maxCamZoom);
    if (z == _camZoom) return;
    setState(() => _camZoom = z);
    widget.controller.setCameraZoom(z);
  }

  void _onMainDoubleTap() {
    if (_selfMain) {
      setState(() => _camZoom = 1.0);
      widget.controller.setCameraZoom(1.0);
    } else {
      _zoom.value = Matrix4.identity(); // reset remote display-zoom
    }
  }

  void _resetZoomForFlip() {
    _camZoom = 1.0;
    _zoomBase = 1.0;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _hideTimer?.cancel();
    _remoteSub?.cancel();
    _reactionSub?.cancel();
    _zoom.dispose();
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

  /// The main (full-screen) view: your own camera when swapped in, else the
  /// partner. Falls back to a clean cover when video isn't available.
  Widget _buildMainContent(Color accent) {
    if (_selfMain) {
      if (_showSelfPreview) {
        return RTCVideoView(
          _local,
          mirror: widget.controller.usingFrontCamera,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
      }
      return _AvatarBackdrop(
        name: 'You',
        avatarFile: null,
        accent: accent,
        subtitle: 'Camera off',
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: widget.controller.peerVideoOff,
      builder: (context, peerOff, _) {
        if (_ready && _remoteHasVideo && !peerOff) {
          return InteractiveViewer(
            transformationController: _zoom,
            minScale: 1.0,
            maxScale: 5.0,
            clipBehavior: Clip.hardEdge,
            child: RTCVideoView(
              _remote,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          );
        }
        return _AvatarBackdrop(
          name: widget.name,
          avatarFile: widget.avatarFile,
          accent: accent,
          subtitle: peerOff ? 'Camera off' : null,
        );
      },
    );
  }

  /// The small PIP tile: the partner when you're swapped to main, else your own
  /// camera (with the recording/camera-off cover).
  Widget _buildPipContent() {
    if (_selfMain) {
      return ValueListenableBuilder<bool>(
        valueListenable: widget.controller.peerVideoOff,
        builder: (context, peerOff, _) {
          if (_ready && _remoteHasVideo && !peerOff) {
            return RTCVideoView(
              _remote,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            );
          }
          return _pipCover(Icons.videocam_off);
        },
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: widget.controller.partnerRecording,
      builder: (context, recording, _) {
        if (_showSelfPreview && !recording) {
          return RTCVideoView(
            _local,
            mirror: widget.controller.usingFrontCamera,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          );
        }
        return _pipCover(
          recording ? Icons.shield_outlined : Icons.videocam_off,
        );
      },
    );
  }

  Widget _pipCover(IconData icon) => Container(
    color: Colors.black.withValues(alpha: 0.6),
    alignment: Alignment.center,
    child: Icon(icon, color: Colors.white70, size: 28),
  );

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
              // Main view: the partner (default), or your own camera when you've
              // tapped your preview. Tap toggles full-screen; double-tap resets
              // zoom. When your camera is main, pinch drives the real lens zoom;
              // when the partner is main, pinch is a display-only zoom/pan.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: _onMainDoubleTap,
                onScaleStart: _selfMain ? _onZoomStart : null,
                onScaleUpdate: _selfMain ? _onZoomUpdate : null,
                child: _buildMainContent(accent),
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

              // Privacy banners: persistent while the partner records (our
              // camera is force-paused), plus a transient screenshot notice.
              Positioned(
                top: pad.top + 72,
                left: 16,
                right: 16,
                child: ValueListenableBuilder<bool>(
                  valueListenable: widget.controller.partnerRecording,
                  builder: (context, recording, _) {
                    return ValueListenableBuilder<String?>(
                      valueListenable: widget.controller.privacyNotice,
                      builder: (context, notice, _) {
                        final text = recording
                            ? '${widget.name} is recording · your camera is hidden'
                            : notice;
                        if (text == null) return const SizedBox.shrink();
                        return Center(
                          child: _PrivacyBanner(text: text, danger: recording),
                        );
                      },
                    );
                  },
                ),
              ),

              // Draggable picture-in-picture tile. Shows your camera by default,
              // or the partner when you've swapped yourself to the main view.
              // Tap to swap; drag to reposition.
              if (_ready)
                Positioned(
                  left: pip.dx.clamp(8.0, constraints.maxWidth - pipW - 8),
                  // Clear of the name and controls; in landscape there's no
                  // room for both, so the bounds collapse to the top.
                  top: pip.dy.clamp(
                    pad.top + 8,
                    max(
                      pad.top + 8,
                      constraints.maxHeight - pipH - _videoControlsReserve,
                    ),
                  ),
                  width: pipW,
                  height: pipH,
                  child: GestureDetector(
                    onTap: _swapMainPip,
                    onPanUpdate: (d) => setState(() => _pipPos = pip + d.delta),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildPipContent(),
                          // Flip rides on your own preview.
                          if (!_selfMain && _showSelfPreview)
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: _flipButton(),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Controls — fade out in full-screen mode; touching them keeps
              // them up (resets the auto-hide).
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !_controlsShown,
                  child: AnimatedOpacity(
                    opacity: _controlsShown ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: Listener(
                      onPointerDown: (_) => _scheduleHide(),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _CallTitle(
                                name: widget.name,
                                status: _statusLabel(),
                                onVideo: true,
                              ),
                              const SizedBox(height: 22),
                              // Five buttons: at large text sizes the labels
                              // widen the row, so scale it down to fit.
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _ControlButton(
                                      icon: Icons.volume_up,
                                      label: 'speaker',
                                      active: _speaker,
                                      toggle: true,
                                      accent: accent,
                                      onVideo: true,
                                      onTap: () {
                                        setState(() => _speaker = !_speaker);
                                        _applyAudioRoute();
                                      },
                                    ),
                                    const SizedBox(width: 12),
                                    _ControlButton(
                                      icon: _muted ? Icons.mic_off : Icons.mic,
                                      label: 'mute',
                                      active: _muted,
                                      toggle: true,
                                      accent: accent,
                                      onVideo: true,
                                      onTap: () {
                                        setState(() => _muted = !_muted);
                                        widget.controller.toggleMute(_muted);
                                      },
                                    ),
                                    const SizedBox(width: 12),
                                    _ControlButton(
                                      icon: Icons.call_end,
                                      label: 'end',
                                      accent: accent,
                                      danger: true,
                                      onVideo: true,
                                      onTap: () => widget.controller.hangup(),
                                    ),
                                    const SizedBox(width: 12),
                                    _ControlButton(
                                      icon: _cameraOn
                                          ? Icons.videocam
                                          : Icons.videocam_off,
                                      label: 'camera',
                                      active: !_cameraOn,
                                      toggle: true,
                                      accent: accent,
                                      onVideo: true,
                                      onTap: () {
                                        setState(() => _cameraOn = !_cameraOn);
                                        widget.controller.setCameraEnabled(
                                          _cameraOn,
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 12),
                                    _ControlButton(
                                      icon: Icons.favorite,
                                      label: 'heart',
                                      accent: accent,
                                      onVideo: true,
                                      iconColor: const Color(0xFFF3A6B6),
                                      onTap: () {
                                        widget.controller.sendReaction();
                                        _scheduleHide();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Floating emoji reactions (non-interactive, above the video).
              Positioned.fill(
                child: IgnorePointer(child: Stack(children: _hearts)),
              ),

              // Flip while your own camera is the main view: the preview then
              // shows the partner, so flip can't ride on it.
              if (_selfMain && _showSelfPreview)
                Positioned(
                  top: pad.top + 8,
                  left: 16,
                  child: AnimatedOpacity(
                    opacity: _controlsShown ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: IgnorePointer(
                      ignoring: !_controlsShown,
                      child: _flipButton(),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Flip between the front and back camera.
  Widget _flipButton() => _RoundIconButton(
    icon: Icons.cameraswitch,
    label: 'Flip camera',
    size: 44,
    onTap: () async {
      await widget.controller.switchCamera();
      if (mounted) setState(_resetZoomForFlip);
    },
  );

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

/// A capture-privacy banner: a red persistent pill while the partner records, or
/// a neutral transient pill for a screenshot notice.
class _PrivacyBanner extends StatelessWidget {
  const _PrivacyBanner({required this.text, this.danger = false});
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: danger
            ? const Color(0xFFC0455B).withValues(alpha: 0.94)
            : Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            danger ? Icons.fiber_manual_record : Icons.photo_camera,
            size: 15,
            color: Colors.white,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact circular icon button (flip camera) for the video overlay.
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 48,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF15101D).withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 1,
            ),
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.45),
        ),
      ),
    );
  }
}

/// A single emoji reaction that floats up the screen, fades, and removes itself.
class _FloatingHeart extends StatefulWidget {
  const _FloatingHeart({
    super.key,
    required this.emoji,
    required this.startX,
    required this.drift,
    required this.onDone,
  });
  final String emoji;
  final double startX; // -1..1 horizontal start (Alignment x)
  final double drift; // horizontal drift over the rise
  final VoidCallback onDone;

  @override
  State<_FloatingHeart> createState() => _FloatingHeartState();
}

class _FloatingHeartState extends State<_FloatingHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) widget.onDone();
        })
        ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final y = 1.0 - t * 1.25; // bottom → upper area
        final x = (widget.startX + widget.drift * t).clamp(-1.0, 1.0);
        final opacity = (t < 0.12 ? t / 0.12 : (1 - (t - 0.12) / 0.88)).clamp(
          0.0,
          1.0,
        );
        final scale =
            0.7 +
            0.5 * Curves.easeOutBack.transform((t / 0.25).clamp(0.0, 1.0));
        return Align(
          alignment: Alignment(x, y),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Text(widget.emoji, style: const TextStyle(fontSize: 40)),
            ),
          ),
        );
      },
    );
  }
}

/// The gradient + breathing-avatar backdrop shown behind a video call until the
/// partner's camera is on screen (matches the voice-call palette).
class _AvatarBackdrop extends StatelessWidget {
  const _AvatarBackdrop({
    required this.name,
    required this.avatarFile,
    required this.accent,
    this.subtitle,
  });
  final String name;
  final File? avatarFile;
  final Color accent;

  /// Optional line under the name (e.g. "Camera off").
  final String? subtitle;

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
      // Centred in the space above the name and controls, and smaller when
      // that space is short (landscape), so the two never overlap.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final room = max(0.0, constraints.maxHeight - _videoControlsReserve);
          final radius = ((room - 50) / 2).clamp(24.0, 60.0);
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: room,
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
                      child: Avatar(
                        seedText: name,
                        imageFile: avatarFile,
                        radius: radius,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 20),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.videocam_off,
                            size: 15,
                            color: Color(0x99F3ECF1),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            subtitle!,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              color: Color(0x99F3ECF1),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
