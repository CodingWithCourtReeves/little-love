import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import 'chat_info_chrome.dart';

/// Takes the composer's place while the chat is in search mode (#96): a
/// "List" button to the results list, the "2 of 4" counter, and arrows to the
/// older and newer match. One frosted capsule, so the counter reads on any
/// wallpaper.
class SearchMatchBar extends StatelessWidget {
  const SearchMatchBar({
    super.key,
    required this.label,
    required this.onList,
    required this.onOlder,
    required this.onNewer,
  });

  /// The counter ("2 of 4"), or a short status ("No matches"), or '' while
  /// nothing has been typed.
  final String label;
  final VoidCallback onList;

  /// Step to the older / newer match. Null disables the arrow (at the oldest /
  /// newest match, or with no matches).
  final VoidCallback? onOlder;
  final VoidCallback? onNewer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Material(
          key: const Key('search-match-bar'),
          color: infoCardColor(p),
          borderRadius: BorderRadius.circular(26),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                TextButton.icon(
                  key: const Key('search-list'),
                  onPressed: onList,
                  icon: const Icon(Icons.format_list_bulleted, size: 20),
                  label: const Text('List'),
                  style: TextButton.styleFrom(
                    foregroundColor: p.accentUser,
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    label,
                    key: const Key('search-counter'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                _Arrow(
                  key: const Key('search-older'),
                  icon: Icons.keyboard_arrow_up,
                  tooltip: 'Older match',
                  onPressed: onOlder,
                ),
                _Arrow(
                  key: const Key('search-newer'),
                  icon: Icons.keyboard_arrow_down,
                  tooltip: 'Newer match',
                  onPressed: onNewer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 44pt arrow button in the accent.
class _Arrow extends StatelessWidget {
  const _Arrow({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 28),
      color: p.accentUser,
      disabledColor: p.accentUser.withValues(alpha: 0.35),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
    );
  }
}
