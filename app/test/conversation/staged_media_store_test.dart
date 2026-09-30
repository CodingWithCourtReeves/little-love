import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/staged_attachment.dart';
import 'package:littlelove/conversation/staged_media_store.dart';

StagedAttachment _item(String name) => StagedAttachment(
  bytes: Uint8List.fromList([1, 2, 3]),
  filename: name,
  mime: 'image/jpeg',
);

void main() {
  test('staged media is kept per room', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(stagedMediaProvider('r1').notifier).addAll([_item('a.jpg')]);
    expect(c.read(stagedMediaProvider('r1')).single.filename, 'a.jpg');
    expect(c.read(stagedMediaProvider('r2')), isEmpty);
  });

  test('addAll appends, removeAt drops one, clear empties the tray', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final tray = c.read(stagedMediaProvider('r1').notifier);
    tray.addAll([_item('a.jpg'), _item('b.jpg')]);
    tray.addAll([_item('c.jpg')]);
    tray.removeAt(1);
    expect(c.read(stagedMediaProvider('r1')).map((s) => s.filename), [
      'a.jpg',
      'c.jpg',
    ]);
    tray.clear();
    expect(c.read(stagedMediaProvider('r1')), isEmpty);
  });

  test('the tray outlives its listeners (survives leaving the room)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sub = c.listen(stagedMediaProvider('r1'), (_, _) {});
    c.read(stagedMediaProvider('r1').notifier).addAll([_item('a.jpg')]);
    // The conversation page unmounting drops its watch.
    sub.close();
    expect(c.read(stagedMediaProvider('r1')).single.filename, 'a.jpg');
  });
}
