import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_palette.dart';

/// Where one of my own messages stands, as drawn by [StatusMarker]. A failed
/// send has its own treatment (a caption in the chat, an error mark in the
/// home list), so it isn't one of these.
enum StatusMark { sending, sent, read }

/// The delivery marker for my own message: a clock while sending, a heart once
/// sent, a double heart once my partner has read it. Shared by the chat bubble
/// (tucked bottom-right, Telegram style) and the home-screen row, so both say
/// the same thing the same way.
class StatusMarker extends StatelessWidget {
  const StatusMarker(this.mark, {super.key});

  final StatusMark mark;

  @override
  Widget build(BuildContext context) {
    // Spoken by VoiceOver in place of the glyphs, which say nothing alone.
    return Semantics(
      label: switch (mark) {
        StatusMark.sending => 'Sending',
        StatusMark.sent => 'Sent',
        StatusMark.read => 'Read',
      },
      excludeSemantics: true,
      child: _glyph(context.palette),
    );
  }

  Widget _glyph(AppPalette palette) {
    return switch (mark) {
      StatusMark.sent => _heart(palette.accentUser, key: 'status-heart'),
      // Read = a double heart: a soft trailing heart with the full-accent heart
      // overlapping on top. Both tones come from theme tokens (not baked into
      // the asset) so a future palette switcher recolors them together.
      StatusMark.read => SizedBox(
        key: const Key('status-double-heart'),
        height: 11,
        width: 18,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: 0, child: _heart(palette.accentUserSoft)),
            Positioned(left: 6, child: _heart(palette.accentUser)),
          ],
        ),
      ),
      StatusMark.sending => Icon(
        Icons.schedule,
        key: const Key('status-clock'),
        size: 12,
        color: palette.textMuted,
      ),
    };
  }

  static Widget _heart(Color color, {String? key}) => SvgPicture.asset(
    'assets/icons/heart-sent.svg',
    key: key == null ? null : Key(key),
    height: 11,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );
}
