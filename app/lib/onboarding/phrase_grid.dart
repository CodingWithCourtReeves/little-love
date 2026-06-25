import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/twilight.dart';

/// Renders a recovery phrase as a two-column grid of numbered "chips," framed
/// in a surface card. Each word keeps its 1-based index (rendered as "N.") so
/// the user can cross-check position when restoring.
class PhraseGrid extends StatelessWidget {
  const PhraseGrid({super.key, required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.bgSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSoft),
      ),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.6,
        ),
        itemCount: words.length,
        itemBuilder: (_, i) => _Chip(index: i + 1, word: words[i]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.index, required this.word});

  final int index;
  final String word;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: palette.bgCanvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSoft),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$index.',
              style: TwilightType.body.copyWith(
                fontSize: 12,
                color: palette.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              word,
              style: TwilightType.body.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
