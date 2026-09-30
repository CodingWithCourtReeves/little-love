import 'dart:async';
import 'dart:convert';

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
  ComposerDraft Function()? _pending;

  /// What the db holds for [roomId] as far as we know (the last draft loaded or
  /// written), so an unchanged draft isn't re-written. Backgrounding alone
  /// fires inactive, hidden and paused, each of which flushes. Null = unknown.
  String? _lastWritten;

  /// The saved draft for [roomId], or null if none (or the db is unavailable).
  Future<ComposerDraft?> load() async {
    try {
      final draft = await (await _db)?.draftFor(roomId);
      _lastWritten = _signature(draft ?? const ComposerDraft(text: ''));
      return draft;
    } catch (e, st) {
      reportFault(e, st, context: 'draft_load');
      return null;
    }
  }

  /// Save the composer once typing pauses for [delay]. Supersedes any pending
  /// save. [current] is read when the timer fires, not now, so the write
  /// reflects the composer at that moment (e.g. after the saved draft was
  /// restored into it) rather than a stale snapshot.
  void schedule(ComposerDraft Function() current) {
    _pending = current;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Write now: [draft] if given, else whatever [schedule] left pending. No-op
  /// when there's nothing to write or it matches what was last written.
  Future<void> flush([ComposerDraft? draft]) {
    _timer?.cancel();
    _timer = null;
    final toWrite = draft ?? _pending?.call();
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
    final sig = _signature(draft);
    if (sig == _lastWritten) return;
    // Claimed before the write so a duplicate issued meanwhile is skipped;
    // released on failure so the next attempt still writes.
    _lastWritten = sig;
    try {
      await (await _db)?.saveDraft(roomId, draft);
    } catch (e, st) {
      _lastWritten = null;
      reportFault(e, st, context: 'draft_save');
    }
  }

  /// Equality key for a draft as stored: every empty draft is the same (saving
  /// one is a delete), otherwise text plus the quoted reply.
  static String _signature(ComposerDraft d) =>
      d.isEmpty ? '' : jsonEncode({'t': d.text, 'r': d.replyTo?.toJson()});
}
