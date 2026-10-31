import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import 'chat_info_chrome.dart';

/// A frosted search field with a Cancel button beside it, for the top of the
/// search results page (#94) and the chat in search mode (#96).
class ChatSearchField extends StatelessWidget {
  const ChatSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onCancel,
    this.focusNode,
    this.autofocus = false,
    this.fieldKey = const Key('message-search-field'),
    this.cancelKey = const Key('message-search-cancel'),
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCancel;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Keys for tests: the chat's own field and the results page's field can
  /// both be mounted while the page sits above the chat.
  final Key fieldKey;
  final Key cancelKey;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 8),
            decoration: BoxDecoration(
              color: infoCardColor(p),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: p.separatorText),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: autofocus,
                    onChanged: onChanged,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: p.textPrimary, fontSize: 16),
                    cursorColor: p.accentUser,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      hintText: 'Search this chat',
                      hintStyle: TextStyle(color: p.separatorText),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: cancelKey,
          onPressed: onCancel,
          // On a frosted pill like the field: the accent on the bare veil
          // or wallpaper misses 4.5:1 on Rosé.
          style: TextButton.styleFrom(
            foregroundColor: p.accentUser,
            backgroundColor: infoCardColor(p),
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
