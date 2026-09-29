import 'dart:async';

import '../diagnostics/crash_reporting.dart';
import 'composer_draft.dart';
import 'message_db.dart';

/// Debounced, best-effort persistence of one room's [ComposerDraft].
///
/// The conversation page calls [schedule] on every keystroke, [flush] when the
/// app backgrounds or the page goes away, and [clear] on send. Every write
/// goes through the same resolved [MessageDb] future, so writes run in the
/// order they were issued: a [clear] after a [flush] always wins.
///
/// Takes a `Future<MessageDb?>` rather than a `Ref` so the page can capture it
/// in `initState` and still write from `dispose`, where `ref` is unusable. A
/// null db (the store failed to open) makes every call a silent no-op: losing
/// a draft is not worth surfacing, and the send path reports its own db faults.
class DraftAutosave {
  DraftAutosave({
    required this._db,
    required this.roomId,
    this.delay = defaultDelay,
  });

  static const defaultDelay = Duration(milliseconds: 400);

  final Future<MessageDb?> _db;
  final String roomId;
  final Duration delay;

  Timer? _timer;
  ComposerDraft? _pending;

  /// The saved draft for [roomId], or null if none (or the db is unavailable).
  Future<ComposerDraft?> load() async {
    try {
      return await (await _db)?.draftFor(roomId);
    } catch (e, st) {
      reportFault(e, st, context: 'draft_load');
      return null;
    }
  }

  /// Save [draft] once typing pauses for [delay]. Supersedes any pending save.
  void schedule(ComposerDraft draft) {
    _pending = draft;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Write now: [draft] if given, else whatever [schedule] left pending. No-op
  /// when there's nothing to write.
  Future<void> flush([ComposerDraft? draft]) {
    _timer?.cancel();
    _timer = null;
    final toWrite = draft ?? _pending;
    _pending = null;
    if (toWrite == null) return Future.value();
    return _write(toWrite);
  }

  /// Drop any pending save and delete the stored draft (the composer was sent).
  Future<void> clear() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    return _write(const ComposerDraft(text: ''));
  }

  /// Cancel a pending save without writing it. Call [flush] first to keep it.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _write(ComposerDraft draft) async {
    try {
      await (await _db)?.saveDraft(roomId, draft);
    } catch (e, st) {
      reportFault(e, st, context: 'draft_save');
    }
  }
}
