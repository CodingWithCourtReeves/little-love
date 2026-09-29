import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/staged_attachment.dart';

/// Media picked onto a room's composer tray but not sent yet.
///
/// Lives in a (non-autoDispose) provider rather than the conversation page's
/// state so the tray survives leaving the room and backgrounding. It is kept
/// in memory only: the items are raw plaintext bytes, sometimes hundreds of MB,
/// so they are never written to disk. An app kill loses them; the text half of
/// the draft is persisted separately (see [ComposerDraft]). Sign-out
/// invalidates the provider.
class StagedMediaStore extends FamilyNotifier<List<StagedAttachment>, String> {
  @override
  List<StagedAttachment> build(String roomId) => const [];

  void addAll(List<StagedAttachment> items) {
    if (items.isEmpty) return;
    state = List.unmodifiable([...state, ...items]);
  }

  void removeAt(int index) {
    state = List.unmodifiable([...state]..removeAt(index));
  }

  void clear() {
    if (state.isEmpty) return;
    state = const [];
  }
}

final stagedMediaProvider =
    NotifierProvider.family<StagedMediaStore, List<StagedAttachment>, String>(
      StagedMediaStore.new,
    );
