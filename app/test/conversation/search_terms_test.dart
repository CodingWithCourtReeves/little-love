import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/search_terms.dart';

void main() {
  String marked(String text, String query) =>
      searchMatchRanges(text, query).map((r) => r.textInside(text)).join('|');

  test('a match runs from a word-start prefix to the end of the word', () {
    expect(
      marked('Strawberry shortcake this weekend?', 'strawberr'),
      'Strawberry',
    );
    expect(
      marked('They only had the sad strawberries', 'STRAWBERR'),
      'strawberries',
    );
  });

  test('only word starts match, like the search index', () {
    // "berr" is inside "strawberry", not the start of a word.
    expect(marked('strawberry', 'berr'), '');
    expect(marked('a berry, then strawberry', 'berr'), 'berry');
  });

  test('every word of the query is marked, wherever it appears', () {
    expect(marked('cake and more cake, then pie', 'cake pie'), 'cake|cake|pie');
  });

  test('punctuation in the query is ignored, as the index ignores it', () {
    expect(marked('cake please', 'cake!'), 'cake');
    expect(marked('see you at 7pm', '7p'), '7pm');
  });

  test('an empty or punctuation-only query marks nothing', () {
    expect(searchMatchRanges('anything', ''), isEmpty);
    expect(searchMatchRanges('anything', ' -*" '), isEmpty);
  });

  test(
    'splitByRanges marks the matches inside a span that starts mid-body',
    () {
      // The body is "see www.cake.com now"; the link span starts at offset 4.
      const body = 'see www.cake.com now';
      final ranges = [const TextRange(start: 8, end: 12)]; // "cake"
      final pieces = splitByRanges('www.cake.com', 4, ranges);
      expect(pieces.map((p) => '${p.marked ? '*' : ''}${p.text}').toList(), [
        'www.',
        '*cake',
        '.com',
      ]);
      expect(body.substring(8, 12), 'cake');
      // A span with no match in it comes back whole.
      expect(splitByRanges('now', 17, ranges), [(text: 'now', marked: false)]);
    },
  );
}
