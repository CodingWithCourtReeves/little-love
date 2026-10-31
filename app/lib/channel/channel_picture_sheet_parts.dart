import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_palette.dart';
import 'channel_picture.dart';

/// A 44pt-tall text button for the sheet header and the Remove row.
class SheetTextButton extends StatelessWidget {
  const SheetTextButton({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
    this.bold = false,
  });

  final String label;
  final Color color;
  final bool bold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        child: Center(
          widthFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 17,
                color: color,
                fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Photo | Symbol segmented control.
class PictureTabs extends StatelessWidget {
  const PictureTabs({super.key, required this.symbolTab, required this.onTab});

  final bool symbolTab;
  final ValueChanged<bool> onTab;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget seg(String label, bool isSymbol) {
      final selected = symbolTab == isSymbol;
      return Expanded(
        child: GestureDetector(
          key: Key('channel-picture-tab-${isSymbol ? 'symbol' : 'photo'}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => onTab(isSymbol),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? p.bubblePartnerBg : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.bgSurfaceAlt,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(children: [seg('Photo', false), seg('Symbol', true)]),
    );
  }
}

/// One row of the Photo tab.
class PhotoRow {
  const PhotoRow(this.keyName, this.icon, this.label, this.onTap);
  final String keyName;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// The Photo tab's card of three rows.
class PhotoRowsCard extends StatelessWidget {
  const PhotoRowsCard({super.key, required this.rows});

  final List<PhotoRow> rows;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.bubblePartnerBg,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: p.borderSoft),
            InkWell(
              key: Key(rows[i].keyName),
              onTap: rows[i].onTap,
              child: SizedBox(
                height: 50,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(rows[i].icon, size: 20, color: p.accentUser),
                      const SizedBox(width: 12),
                      Text(
                        rows[i].label,
                        style: TextStyle(fontSize: 16, color: p.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The Symbol tab: a 6-column symbol grid and a row of colour swatches.
class SymbolPanel extends StatelessWidget {
  const SymbolPanel({
    super.key,
    required this.symbol,
    required this.color,
    required this.onSymbol,
    required this.onColor,
  });

  final ChannelSymbol symbol;
  final ChannelColor color;
  final ValueChanged<ChannelSymbol> onSymbol;
  final ValueChanged<ChannelColor> onColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget cell(ChannelSymbol s) {
      final selected = s == symbol;
      return GestureDetector(
        key: Key('channel-symbol-${s.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onSymbol(s),
        child: Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: p.bubblePartnerBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              width: 2,
              color: selected ? p.accentUser : Colors.transparent,
            ),
          ),
          child: SvgPicture.asset(
            'assets/channel_symbols/${s.name}.svg',
            width: 24,
            height: 24,
            colorFilter: ColorFilter.mode(p.separatorText, BlendMode.srcIn),
          ),
        ),
      );
    }

    const all = ChannelSymbol.values;
    return Column(
      children: [
        for (var r = 0; r < all.length; r += 6) ...[
          if (r > 0) const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final s in all.skip(r).take(6)) cell(s)],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final c in ChannelColor.values)
              GestureDetector(
                key: Key('channel-color-${c.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onColor(c),
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      width: 2,
                      color: c == color ? p.accentUser : Colors.transparent,
                    ),
                  ),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.channelSwatches[c.index].tint,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
