import 'package:flutter/painting.dart';

/// Where [query]'s words match in [text], for marking in-chat search hits
/// inside their bubbles (#96). Sorted, non-overlapping.
///
/// Mirrors [MessageDb.search]'s prefix match: each query word, lowercased and
/// stripped to letters and digits, matches the start of a word in [text], and
/// the mark runs to the end of that word ("strawberr" marks all of
/// "Strawberries"). Case-insensitive. Unlike the FTS index it doesn't fold
/// accents, so "cafe" finds "café" in search but marks nothing in it.
List<TextRange> searchMatchRanges(String text, String query) {
  final terms = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .map((t) => t.replaceAll(_nonWord, ''))
      .where((t) => t.isNotEmpty)
      .toList();
  if (terms.isEmpty || text.isEmpty) return const [];
  final lower = text.toLowerCase();
  // A few characters change length when lowercased ("İ"); offsets into
  // [lower] would then be off, so mark nothing rather than the wrong letters.
  if (lower.length != text.length) return const [];
  final ranges = <TextRange>[];
  var i = 0;
  while (i < text.length) {
    final startsWord = _isWord(text, i) && (i == 0 || !_isWord(text, i - 1));
    if (startsWord) {
      for (final term in terms) {
        if (!lower.startsWith(term, i)) continue;
        var end = i + term.length;
        while (end < text.length && _isWord(text, end)) {
          end++;
        }
        ranges.add(TextRange(start: i, end: end));
        i = end;
        break;
      }
    }
    i++;
  }
  return ranges;
}

/// A piece of a span's text, and whether it falls inside a match.
typedef MarkedPiece = ({String text, bool marked});

/// Splits [text], which starts at [offset] in the string [ranges] index, into
/// unmarked and marked pieces, in order. Lets a caller that renders a body as
/// several spans (links, emoji runs) mark the matches inside each one.
List<MarkedPiece> splitByRanges(
  String text,
  int offset,
  List<TextRange> ranges,
) {
  if (ranges.isEmpty) return [(text: text, marked: false)];
  final pieces = <MarkedPiece>[];
  final end = offset + text.length;
  var cursor = offset;
  for (final r in ranges) {
    if (r.end <= cursor) continue;
    if (r.start >= end) break;
    final from = r.start < cursor ? cursor : r.start;
    final to = r.end > end ? end : r.end;
    if (from > cursor) {
      pieces.add((
        text: text.substring(cursor - offset, from - offset),
        marked: false,
      ));
    }
    pieces.add((
      text: text.substring(from - offset, to - offset),
      marked: true,
    ));
    cursor = to;
  }
  if (cursor < end) {
    pieces.add((text: text.substring(cursor - offset), marked: false));
  }
  return pieces;
}

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]', unicode: true);
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWord(String s, int i) => _wordChar.hasMatch(s[i]);
