import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import 'chat_info_chrome.dart';

/// Whose messages a search covers (#95). With exactly two people in a chat,
/// the sender is the one filter that matters.
enum SenderFilter { all, partner, me }

/// The chip row under the search field (#95): All / "From Kat" / From me
/// filter the results by sender; Photos and Links open those galleries rather
/// than filtering the text results. Scrolls sideways when it doesn't fit.
class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({
    super.key,
    required this.partnerName,
    required this.selected,
    required this.onSelect,
    required this.onPhotos,
    required this.onLinks,
  });

  /// Shown as "From [partnerName]".
  final String partnerName;
  final SenderFilter selected;
  final ValueChanged<SenderFilter> onSelect;
  final VoidCallback onPhotos;
  final VoidCallback onLinks;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('search-chips'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          for (final (filter, label) in [
            (SenderFilter.all, 'All'),
            (SenderFilter.partner, 'From $partnerName'),
            (SenderFilter.me, 'From me'),
          ])
            _Chip(
              key: Key('search-chip-${filter.name}'),
              label: label,
              selected: selected == filter,
              onTap: () => onSelect(filter),
            ),
          _Chip(
            key: const Key('search-chip-photos'),
            label: 'Photos',
            icon: Icons.photo_outlined,
            selected: false,
            onTap: onPhotos,
          ),
          _Chip(
            key: const Key('search-chip-links'),
            label: 'Links',
            icon: Icons.link,
            selected: false,
            onTap: onLinks,
          ),
        ],
      ),
    );
  }
}

/// One chip: a 36pt pill inside a 44pt-tall tap area.
class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // The selected chip matches the gallery's selected tab.
    final fg = selected
        ? (p.brightness == Brightness.dark ? p.bgCanvas : Colors.white)
        : p.textPrimary;
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? p.accentUser : infoCardColor(p),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: selected ? p.accentUser : p.borderSoft),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
