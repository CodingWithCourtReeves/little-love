import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/presence_state.dart';

void main() {
  test('defaults to offline; setOnline flips it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(presenceProvider('kaitlyn')), isFalse);
    c.read(presenceProvider('kaitlyn').notifier).setOnline(true);
    expect(c.read(presenceProvider('kaitlyn')), isTrue);
    c.read(presenceProvider('kaitlyn').notifier).setOnline(false);
    expect(c.read(presenceProvider('kaitlyn')), isFalse);
  });

  test('presence is keyed per username, independent', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(presenceProvider('kaitlyn').notifier).setOnline(true);
    expect(c.read(presenceProvider('kaitlyn')), isTrue);
    expect(c.read(presenceProvider('court')), isFalse);
  });
}
