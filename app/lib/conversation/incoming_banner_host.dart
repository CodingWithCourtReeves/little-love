import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../inbox/active_room_provider.dart';
import '../theme/app_palette.dart';
import 'incoming_banner_provider.dart';

/// Mounted once at the app shell (via `MaterialApp.builder`), above the
/// navigator, so it floats over whatever conversation is on screen. Watches
/// [incomingBannerProvider] and slides a tappable banner down from the top when
/// a partner message lands in a room you're not currently viewing.
///
/// Tapping reuses the existing deep-link path: it sets [requestedRoomProvider],
/// which `HomeScreen` already listens for and pushes the matching room (the same
/// flow a push-notification tap uses) — so no separate navigator key is needed.
class IncomingBannerHost extends ConsumerStatefulWidget {
  const IncomingBannerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IncomingBannerHost> createState() => _IncomingBannerHostState();
}

class _IncomingBannerHostState extends ConsumerState<IncomingBannerHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 240),
      )..addStatusListener((s) {
        // Once the slide-out finishes, drop the banner from the tree.
        if (s == AnimationStatus.dismissed && mounted) {
          setState(() => _current = null);
        }
      });

  Timer? _autoDismiss;
  IncomingBanner? _current;

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onEvent(IncomingBanner? next) {
    _autoDismiss?.cancel();
    if (next == null) {
      // Cleared (tapped / swiped / timed out): slide out. The status listener
      // finalizes removal once the reverse completes.
      if (!_ctrl.isDismissed) _ctrl.reverse();
      return;
    }
    // New (or replacing) banner: show it and (re)start the dismiss timer.
    setState(() => _current = next);
    _ctrl.forward(from: 0);
    _autoDismiss = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        ref.read(incomingBannerProvider.notifier).clear(msgId: next.msgId);
      }
    });
  }

  void _open(IncomingBanner b) {
    // Reuse the notification-tap deep link: HomeScreen pushes this room.
    ref.read(requestedRoomProvider.notifier).state = b.roomId;
    ref.read(incomingBannerProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<IncomingBanner?>(
      incomingBannerProvider,
      (_, next) => _onEvent(next),
    );
    final banner = _current;
    return Stack(
      children: [
        widget.child,
        if (banner != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, -1),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: _ctrl,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeInCubic,
                    ),
                  ),
              child: SafeArea(bottom: false, child: _banner(context, banner)),
            ),
          ),
      ],
    );
  }

  Widget _banner(BuildContext context, IncomingBanner b) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: GestureDetector(
        // Swipe up to dismiss early.
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < 0) {
            ref.read(incomingBannerProvider.notifier).clear();
          }
        },
        child: Material(
          key: const Key('incoming-banner'),
          color: palette.bgSurface,
          elevation: 6,
          borderRadius: BorderRadius.circular(16),
          shadowColor: Colors.black.withValues(alpha: 0.25),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _open(b),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  SvgPicture.asset(
                    'assets/icons/message-heart.svg',
                    width: 22,
                    height: 22,
                    colorFilter: ColorFilter.mode(
                      palette.accentUser,
                      BlendMode.srcIn,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          b.roomName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: palette.textPrimary,
                          ),
                        ),
                        if (b.preview.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            b.preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 13,
                              color: palette.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
