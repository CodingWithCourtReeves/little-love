import 'package:flutter/material.dart';

import '../conversation/chat_separator.dart';
import '../theme/app_palette.dart';

/// A centred timeline line for a channel change ("You renamed the channel to
/// Us"), styled like a [ChatSeparator]. When [failed], it adds a warning-tone
/// "Not sent. Tap to retry." and the whole line becomes a 44pt tap target that
/// calls [onRetry].
class ChannelLineView extends StatelessWidget {
  const ChannelLineView({
    super.key,
    required this.text,
    this.failed = false,
    this.onRetry,
  });

  final String text;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = TextStyle(
      color: p.separatorText,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    );
    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: p.bgSurface.withValues(alpha: ChatSeparator.scrimAlpha),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: text),
            if (failed)
              TextSpan(
                text: ' Not sent. Tap to retry.',
                style: TextStyle(color: p.warningTone),
              ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
    final line = Center(child: label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: failed
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRetry,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: line,
              ),
            )
          : line,
    );
  }
}
