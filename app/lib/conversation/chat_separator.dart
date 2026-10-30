import 'package:flutter/material.dart';

import '../theme/app_palette.dart';

/// A quiet day or time separator in the chat ("Today 8:05 PM"), #89.
///
/// The issue asks for bare muted text, falling back to a translucent pill where
/// a wallpaper is too busy. Every shipped wallpaper is: each has a stretch
/// (Twilight's pale rose, Mauve & Sage's sage, Deep Dusk's wine) where no
/// single text color reaches 4.5:1 bare. So the label always sits on a light
/// [scrimAlpha] scrim of `bgSurface`, much fainter than the old solid pill, and
/// uses [AppPalette.separatorText], which clears 4.5:1 over that scrim on
/// every wallpaper in both palettes (checked in `chat_separator_test.dart`).
class ChatSeparator extends StatelessWidget {
  const ChatSeparator(this.label, {super.key});

  /// "Today 6:12 PM", "Yesterday 9:41 PM", "Oct 3 9:41 PM".
  final String label;

  /// Opacity of the `bgSurface` scrim behind the label (the old pill was 0.86).
  static const double scrimAlpha = 0.5;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      // More room above than below: the label introduces the messages under
      // it, so it sits closer to them.
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: p.bgSurface.withValues(alpha: scrimAlpha),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: p.separatorText,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
