import 'package:flutter/material.dart';

import 'app_palette.dart';

/// Show a brief Telegram-style toast: a rounded dark pill that slides up and
/// fades in near the bottom of the screen, holds, then fades out and removes
/// itself. Floats over everything (its own [OverlayEntry]) and ignores pointer
/// events, so it never blocks the UI underneath.
void showLoveToast(BuildContext context, String message, {IconData? icon}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _LoveToast(
      message: message,
      icon: icon,
      onDismissed: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

class _LoveToast extends StatefulWidget {
  const _LoveToast({
    required this.message,
    required this.onDismissed,
    this.icon,
  });

  final String message;
  final IconData? icon;
  final VoidCallback onDismissed;

  @override
  State<_LoveToast> createState() => _LoveToastState();
}

class _LoveToastState extends State<_LoveToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.6),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _c.forward();
    _scheduleDismiss();
  }

  Future<void> _scheduleDismiss() async {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    await _c.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Sit above the composer / keyboard, centered horizontally.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96 + keyboard,
      child: IgnorePointer(
        child: Center(
          child: FadeTransition(
            opacity: _fade,
            child: SlideTransition(position: _slide, child: _pill()),
          ),
        ),
      ),
    );
  }

  Widget _pill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: context.palette.textPrimary.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 16, color: Colors.white),
            const SizedBox(width: 8),
          ],
          Text(
            widget.message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
