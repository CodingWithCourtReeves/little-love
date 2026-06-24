import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/twilight.dart';

/// Shared header for the new-user onboarding screens: an optional step marker
/// (e.g. "Step 1 of 2 · Recovery phrase") above a screen title. Keeps the
/// auth screens visually in sync instead of each one inventing its own
/// spacing and type.
class OnboardingHeader extends StatelessWidget {
  const OnboardingHeader({super.key, this.step, required this.title});

  /// Small uppercase marker shown above the title. Null hides it.
  final String? step;
  final String title;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (step != null) ...[
          Text(
            step!.toUpperCase(),
            style: TwilightType.annotation.copyWith(color: palette.accentSage),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          title,
          style: TwilightType.display.copyWith(
            fontSize: 26,
            color: palette.textPrimary,
          ),
        ),
      ],
    );
  }
}
