import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/composer_draft.dart';
import 'package:littlelove/conversation/draft_autosave.dart';
import 'package:littlelove/conversation/message_db.dart';

/// Records draft writes in memory. Only the draft surface is exercised here;
/// anything else is a test bug, so it throws.
class _RecordingDb implements MessageDb {
  final Map<String, ComposerDraft> drafts = {};
  int writes = 0;

  @override
  Future<ComposerDraft?> draftFor(String roomId) async => drafts[roomId];

  @override
  Future<void> saveDraft(String roomId, ComposerDraft draft) async {
    writes++;
    if (draft.isEmpty) {
      drafts.remove(roomId);
    } else {
      drafts[roomId] = draft;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const delay = DraftAutosave.defaultDelay;

  test('schedule debounces rapid keystrokes into one write of the latest', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.schedule(() => const ComposerDraft(text: 'h'));
      saver.schedule(() => const ComposerDraft(text: 'he'));
      saver.schedule(() => const ComposerDraft(text: 'hey'));
      async.elapse(delay ~/ 2);
      expect(db.writes, 0);
      async.elapse(delay);
      expect(db.writes, 1);
      expect(db.drafts['r1']!.text, 'hey');
      saver.dispose();
    });
  });

  test('flush writes the pending draft immediately and cancels the timer', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.schedule(() => const ComposerDraft(text: 'leaving now'));
      saver.flush();
      async.flushMicrotasks();
      expect(db.drafts['r1']!.text, 'leaving now');
      async.elapse(delay * 2);
      expect(db.writes, 1, reason: 'the debounced write must not re-fire');
      saver.dispose();
    });
  });

  test('flush with an explicit draft writes that draft', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.flush(const ComposerDraft(text: 'from dispose'));
      async.flushMicrotasks();
      expect(db.drafts['r1']!.text, 'from dispose');
      saver.dispose();
    });
  });

  test('flush with nothing pending does not write', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.flush();
      async.flushMicrotasks();
      expect(db.writes, 0);
      saver.dispose();
    });
  });

  test('clear drops a pending save and deletes the stored draft (on send)', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      db.drafts['r1'] = const ComposerDraft(text: 'old');
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.schedule(() => const ComposerDraft(text: 'about to send'));
      saver.clear();
      async.elapse(delay * 2);
      expect(
        db.drafts,
        isEmpty,
        reason: 'a late debounced save resurrected it',
      );
      saver.dispose();
    });
  });

  test('load returns the saved draft for the room', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      db.drafts['r1'] = const ComposerDraft(text: 'welcome back');
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      ComposerDraft? loaded;
      saver.load().then((d) => loaded = d);
      async.flushMicrotasks();
      expect(loaded!.text, 'welcome back');
      saver.dispose();
    });
  });

  test('an unavailable db makes drafts a silent no-op', () {
    fakeAsync((async) {
      final saver = DraftAutosave(db: Future.value(null), roomId: 'r1');
      ComposerDraft? loaded = const ComposerDraft(text: 'sentinel');
      saver.load().then((d) => loaded = d);
      saver.schedule(() => const ComposerDraft(text: 'x'));
      async.elapse(delay * 2);
      saver.flush(const ComposerDraft(text: 'y'));
      saver.clear();
      async.flushMicrotasks();
      expect(loaded, isNull);
      saver.dispose();
    });
  });

  test('dispose cancels a pending save without writing', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.schedule(() => const ComposerDraft(text: 'x'));
      saver.dispose();
      async.elapse(delay * 2);
      expect(db.writes, 0);
    });
  });

  test('a scheduled save writes the composer as it is when the timer fires, '
      'not a stale snapshot from when it was scheduled', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      var current = const ComposerDraft(text: '');
      saver.schedule(() => current);
      // e.g. the saved draft is restored into the composer meanwhile.
      current = const ComposerDraft(text: 'restored text');
      async.elapse(delay * 2);
      expect(db.drafts['r1']!.text, 'restored text');
      saver.dispose();
    });
  });

  test('writing the same draft again is skipped (backgrounding fires '
      'inactive, hidden and paused)', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.flush(const ComposerDraft(text: 'same'));
      saver.flush(const ComposerDraft(text: 'same'));
      saver.flush(const ComposerDraft(text: 'same'));
      async.flushMicrotasks();
      expect(db.writes, 1);
      saver.flush(const ComposerDraft(text: 'changed'));
      async.flushMicrotasks();
      expect(db.writes, 2);
      saver.dispose();
    });
  });

  test('a freshly loaded draft counts as already written', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      db.drafts['r1'] = const ComposerDraft(text: 'as saved');
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.load();
      async.flushMicrotasks();
      saver.flush(const ComposerDraft(text: 'as saved'));
      async.flushMicrotasks();
      expect(db.writes, 0);
      saver.dispose();
    });
  });

  test('after clear, writing the old text again is not skipped', () {
    fakeAsync((async) {
      final db = _RecordingDb();
      final saver = DraftAutosave(db: Future.value(db), roomId: 'r1');
      saver.flush(const ComposerDraft(text: 'x'));
      saver.clear();
      saver.flush(const ComposerDraft(text: 'x'));
      async.flushMicrotasks();
      expect(db.drafts['r1']!.text, 'x');
      saver.dispose();
    });
  });
}
