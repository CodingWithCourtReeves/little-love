import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/bip39.dart';
import '../theme/app_palette.dart';
import '../theme/twilight.dart';

/// A 12-box recovery-phrase input. One numbered slot per word, with:
///
/// - **paste-to-fill-all**: pasting a whole phrase into any box splits it
///   across the remaining boxes (also a dedicated Paste button),
/// - **auto-advance**: typing a word then space jumps to the next box,
/// - **BIP39 autocomplete**: a suggestion strip for the focused box, plus a
///   red tint on a finished box whose word isn't in the wordlist (catches
///   typos before sign-in).
///
/// Emits the current phrase (the boxes joined by single spaces) via
/// [onChanged]; the parent decides when all [wordCount] words are present.
class PhraseInput extends StatefulWidget {
  const PhraseInput({super.key, required this.onChanged, this.wordCount = 12});

  final ValueChanged<String> onChanged;
  final int wordCount;

  @override
  State<PhraseInput> createState() => _PhraseInputState();
}

class _PhraseInputState extends State<PhraseInput> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _nodes;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      widget.wordCount,
      (_) => TextEditingController(),
    );
    _nodes = List.generate(widget.wordCount, (_) => FocusNode());
    for (final n in _nodes) {
      n.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  int get _focusedIndex => _nodes.indexWhere((n) => n.hasFocus);

  void _emit() {
    widget.onChanged(_controllers.map((c) => c.text.trim()).join(' '));
  }

  /// Place [parts] into the boxes starting at [start], then move focus to the
  /// first still-empty box after the fill (or unfocus if the phrase is full).
  void _distribute(int start, List<String> parts) {
    for (var k = 0; k < parts.length && (start + k) < widget.wordCount; k++) {
      _controllers[start + k].text = parts[k].toLowerCase();
    }
    final next = start + parts.length;
    if (next < widget.wordCount) {
      _nodes[next].requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
    setState(() {});
    _emit();
  }

  void _handleChanged(int i, String value) {
    if (value.contains(RegExp(r'\s'))) {
      final parts = value
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length > 1) {
        _distribute(i, parts); // a paste
        return;
      }
      // A single word followed by a space: commit it and advance.
      _controllers[i].text = parts.isEmpty ? '' : parts.first.toLowerCase();
      if (i + 1 < widget.wordCount) {
        _nodes[i + 1].requestFocus();
      }
    }
    setState(() {}); // refresh suggestions + validity tint
    _emit();
  }

  Future<void> _pasteAll() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    final parts = text
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    _distribute(0, parts);
  }

  void _applySuggestion(int i, String word) {
    _controllers[i].text = word;
    if (i + 1 < widget.wordCount) {
      _nodes[i + 1].requestFocus();
    }
    setState(() {});
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final focused = _focusedIndex;
    final suggestions = focused < 0
        ? const <String>[]
        : bip39Suggestions(_controllers[focused].text);
    final showSuggestions =
        suggestions.isNotEmpty &&
        !(suggestions.length == 1 &&
            suggestions.first == _controllers[focused].text.trim());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _pasteAll,
            style: TextButton.styleFrom(foregroundColor: palette.accentSage),
            icon: const Icon(Icons.content_paste_outlined, size: 16),
            label: const Text('Paste'),
          ),
        ),
        const SizedBox(height: 4),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 4.2,
          ),
          itemCount: widget.wordCount,
          itemBuilder: (_, i) => _box(palette, i),
        ),
        SizedBox(
          height: 44,
          child: showSuggestions
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, s) =>
                        _suggestionChip(palette, focused, suggestions[s]),
                  ),
                )
              : null,
        ),
      ],
    );
  }

  Widget _box(AppPalette palette, int i) {
    final hasFocus = _nodes[i].hasFocus;
    final text = _controllers[i].text.trim().toLowerCase();
    final invalid = !hasFocus && text.isNotEmpty && !isBip39Word(text);
    final border = hasFocus
        ? palette.accentUser
        : (invalid ? palette.warningTone : palette.borderSoft);
    return Container(
      decoration: BoxDecoration(
        color: palette.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: hasFocus ? 1.5 : 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '${i + 1}',
              style: TwilightType.body.copyWith(
                fontSize: 11,
                color: palette.textMuted,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              key: ValueKey('phrase-word-$i'),
              controller: _controllers[i],
              focusNode: _nodes[i],
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: i + 1 < widget.wordCount
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: (_) {
                if (i + 1 < widget.wordCount) _nodes[i + 1].requestFocus();
              },
              onChanged: (v) => _handleChanged(i, v),
              decoration: const InputDecoration.collapsed(hintText: ''),
              style: TwilightType.body.copyWith(
                fontWeight: FontWeight.w500,
                color: invalid ? palette.warningTone : palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _suggestionChip(AppPalette palette, int focused, String word) {
    return GestureDetector(
      onTap: () => _applySuggestion(focused, word),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: palette.bgSurfaceAlt,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.borderSoft),
        ),
        child: Text(
          word,
          style: TwilightType.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: palette.textPrimary,
          ),
        ),
      ),
    );
  }
}
