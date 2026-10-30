import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'composer_draft.dart';
import 'message_db.dart';

/// The unsent draft text for one room, as the home-screen row shows it
/// ("Draft: …"), or null when there's nothing worth showing.
///
/// Seeded from [MessageDb] on first read, then kept current by the
/// conversation page: its [DraftAutosave] reports every write through [set]
/// (see `onWritten`). Writes land asynchronously after the db call, never
/// from inside `dispose`, so updating this from the page's teardown flush
/// doesn't mark the home screen dirty while the widget tree is locked.
class DraftPreviewNotifier extends FamilyNotifier<String?, String> {
  /// True once the page has reported a write. The db seed then stands down: a
  /// load that resolves after a newer write MUST NOT clobber it.
  bool _written = false;

  @override
  String? build(String roomId) {
    _written = false;
    _seed(roomId);
    return null;
  }

  Future<void> _seed(String roomId) async {
    try {
      final draft = await (await ref.read(
        messageDbProvider.future,
      )).draftFor(roomId);
      if (_written) return;
      state = _textOf(draft);
    } catch (_) {
      // Best effort: the preview just shows the last message instead. A db
      // that won't open is reported by the router and by DraftAutosave.
    }
  }

  /// Record what the conversation page just persisted for this room.
  void set(ComposerDraft draft) {
    _written = true;
    state = _textOf(draft);
  }

  /// A draft that is only a quoted reply (no text) has nothing to preview.
  static String? _textOf(ComposerDraft? draft) {
    final text = draft?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

final draftPreviewProvider =
    NotifierProvider.family<DraftPreviewNotifier, String?, String>(
      DraftPreviewNotifier.new,
    );
