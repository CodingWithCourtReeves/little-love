import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/composer_draft.dart';
import 'package:littlelove/conversation/draft_preview_state.dart';
import 'package:littlelove/conversation/message_db.dart';

/// Serves one room's stored draft, resolving only when [release] is called so
/// a test controls when the seed lands. Anything else is a test bug.
class _GatedDraftDb implements MessageDb {
  _GatedDraftDb(this._stored);

  final ComposerDraft? _stored;
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<ComposerDraft?> draftFor(String roomId) async {
    await _gate.future;
    return _stored;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

ProviderContainer _container(MessageDb db) {
  final c = ProviderContainer(
    overrides: [messageDbProvider.overrideWith((_) async => db)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('seeds from the stored draft', () async {
    final db = _GatedDraftDb(const ComposerDraft(text: '  oat milk  '));
    final c = _container(db);
    expect(c.read(draftPreviewProvider('r1')), isNull);
    db.release();
    await pumpEventQueue();
    expect(c.read(draftPreviewProvider('r1')), 'oat milk');
  });

  test('a write that lands before the seed is not clobbered by it', () async {
    final db = _GatedDraftDb(const ComposerDraft(text: 'stale'));
    final c = _container(db);
    c.read(draftPreviewProvider('r1'));
    c
        .read(draftPreviewProvider('r1').notifier)
        .set(const ComposerDraft(text: 'fresh'));
    db.release();
    await pumpEventQueue();
    expect(c.read(draftPreviewProvider('r1')), 'fresh');
  });

  test('clearing the draft (sent) removes the preview', () async {
    final db = _GatedDraftDb(null)..release();
    final c = _container(db);
    final notifier = c.read(draftPreviewProvider('r1').notifier);
    notifier.set(const ComposerDraft(text: 'hello'));
    expect(c.read(draftPreviewProvider('r1')), 'hello');
    notifier.set(const ComposerDraft(text: ''));
    expect(c.read(draftPreviewProvider('r1')), isNull);
  });

  test('a draft that is only whitespace previews as nothing', () async {
    final db = _GatedDraftDb(null)..release();
    final c = _container(db);
    c
        .read(draftPreviewProvider('r1').notifier)
        .set(const ComposerDraft(text: '   \n'));
    expect(c.read(draftPreviewProvider('r1')), isNull);
  });
}
