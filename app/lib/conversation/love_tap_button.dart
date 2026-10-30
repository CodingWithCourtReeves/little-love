import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// The heart inside the composer pill while it's empty (#76). Tapping it sends
/// a love tap. It sits inside the pill rather than replacing the mic, so voice
/// memos keep their press-and-hold slot.
///
/// Pops in when it appears (the composer just emptied) and squeezes while
/// pressed. The haptic and the send are the caller's [onTap].
class LoveTapButton extends StatefulWidget {
  const LoveTapButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<LoveTapButton> createState() => _LoveTapButtonState();
}

class _LoveTapButtonState extends State<LoveTapButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Send a love tap',
      child: GestureDetector(
        key: const Key('composer-love-tap'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        onTap: widget.onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            builder: (context, t, child) =>
                Transform.scale(scale: t, child: child),
            child: AnimatedScale(
              scale: _pressed ? 0.8 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Icon(
                Icons.favorite_rounded,
                color: context.palette.accentUser,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
