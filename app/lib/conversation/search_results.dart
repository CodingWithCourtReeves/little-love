import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../profile/avatar.dart';
import '../profile/profile_store.dart';
import '../theme/app_palette.dart';
import 'chat_info_chrome.dart';
import 'message_search.dart';
import 'time_format.dart';

/// What in-chat search covers, shown under the results (#94).
const searchScopeNote =
    "Searches the messages saved on this iPhone. They're end-to-end "
    'encrypted, so nothing else can search them.';

/// In-chat search results (#94): [SearchHit]s newest first, grouped by day on
/// frosted cards, each row with who said it, when, and a highlighted snippet.
/// Renders the async states too.
class SearchResultsList extends ConsumerWidget {
  const SearchResultsList({
    super.key,
    required this.results,
    required this.selfUsername,
    required this.emptyHint,
    required this.onTap,
  });

  /// Hits in the order [channelSearchProvider] returns them: newest first.
  final AsyncValue<List<SearchHit>> results;
  final String selfUsername;
  final String emptyHint;
  final void Function(SearchHit hit) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    return results.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text('Search failed', style: TextStyle(color: p.textPrimary)),
      ),
      data: (hits) {
        if (hits.isEmpty) {
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 0),
                child: Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textPrimary, fontSize: 15),
                ),
              ),
              const _ScopeNote(),
            ],
          );
        }
        final groups = groupHitsByDay(hits);
        final profiles = ref.watch(profileStoreProvider);
        final now = DateTime.now();
        return ListView.builder(
          key: const Key('search-results'),
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: groups.length + 1,
          itemBuilder: (context, i) {
            if (i == groups.length) return const _ScopeNote();
            final group = groups[i];
            return InfoSection(
              key: ValueKey('search-day-${group.day.toIso8601String()}'),
              caption: dayLabel(group.day, now: now),
              children: [
                for (final hit in group.hits)
                  SearchResultRow(
                    key: Key('search-result-${hit.messageId}'),
                    hit: hit,
                    name: senderName(
                      hit.from,
                      self: selfUsername,
                      profiles: profiles,
                    ),
                    avatarFile: hit.from == selfUsername
                        ? null
                        : profiles.avatarFileFor(hit.from),
                    onTap: () => onTap(hit),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Who sent a message, as search shows it: "You" for [self]; the partner's
/// display name, else their username capitalized the way the room list does.
String senderName(
  String username, {
  required String self,
  required ProfileStore profiles,
}) {
  if (username == self) return 'You';
  final display = profiles.forUsername(username)?.displayName;
  if (display != null && display.isNotEmpty) return display;
  if (username.isEmpty) return username;
  return username[0].toUpperCase() + username.substring(1);
}

/// [hits] (newest first) split into runs by local calendar day, keeping the
/// order. One run per day, since newest-first hits from the same day are
/// always adjacent.
List<({DateTime day, List<SearchHit> hits})> groupHitsByDay(
  List<SearchHit> hits,
) {
  final groups = <({DateTime day, List<SearchHit> hits})>[];
  for (final hit in hits) {
    final day = dateOnly(hit.ts.toLocal());
    if (groups.isNotEmpty && groups.last.day == day) {
      groups.last.hits.add(hit);
    } else {
      groups.add((day: day, hits: [hit]));
    }
  }
  return groups;
}

/// One result: avatar, who said it, the time on the right, and up to two lines
/// of snippet with the match highlighted.
class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    super.key,
    required this.hit,
    required this.name,
    required this.avatarFile,
    required this.onTap,
  });

  final SearchHit hit;

  /// Who said it, as shown ("You", or the partner's name).
  final String name;
  final File? avatarFile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final time = clockTime(
      hit.ts.toLocal(),
      use24h: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(seedText: name, imageFile: avatarFile, radius: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        time,
                        style: TextStyle(fontSize: 13, color: p.separatorText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SnippetText(snippetHtml: hit.snippetHtml),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders FTS5 `snippet()` output (matches wrapped in `<b>…</b>`) as up to
/// two lines with each match on an accent tint ([AppPalette.searchMatch]).
/// The snippet content is our own message text, and the only markup snippet()
/// emits is the bold delimiters we passed it, so a plain split is safe. Shared
/// by the in-chat and global result lists.
class SnippetText extends StatelessWidget {
  const SnippetText({super.key, required this.snippetHtml});

  final String snippetHtml;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final base = TextStyle(color: p.separatorText, fontSize: 14, height: 1.35);
    final match = base.copyWith(backgroundColor: p.searchMatch);
    final spans = <TextSpan>[];
    var rest = snippetHtml;
    while (true) {
      final open = rest.indexOf('<b>');
      if (open < 0) {
        if (rest.isNotEmpty) spans.add(TextSpan(text: rest, style: base));
        break;
      }
      if (open > 0) {
        spans.add(TextSpan(text: rest.substring(0, open), style: base));
      }
      final close = rest.indexOf('</b>', open + 3);
      if (close < 0) {
        spans.add(TextSpan(text: rest.substring(open + 3), style: base));
        break;
      }
      spans.add(TextSpan(text: rest.substring(open + 3, close), style: match));
      rest = rest.substring(close + 4);
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The lock line under the results: what search covers and why nothing else
/// can search it.
class _ScopeNote extends StatelessWidget {
  const _ScopeNote();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      key: const Key('search-scope-note'),
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.lock_outline, size: 14, color: p.separatorText),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              searchScopeNote,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: p.separatorText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
