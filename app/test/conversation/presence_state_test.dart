import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/presence_state.dart';

void main() {
  test('defaults to offline/null; set flips online + lastSeen', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(presenceProvider('kaitlyn')).online, isFalse);
    expect(c.read(presenceProvider('kaitlyn')).lastSeen, isNull);

    final t = DateTime.utc(2026, 6, 24, 17);
    c.read(presenceProvider('kaitlyn').notifier).set(false, lastSeen: t);
    expect(c.read(presenceProvider('kaitlyn')).online, isFalse);
    expect(c.read(presenceProvider('kaitlyn')).lastSeen, t);

    c.read(presenceProvider('kaitlyn').notifier).set(true);
    expect(c.read(presenceProvider('kaitlyn')).online, isTrue);
    expect(c.read(presenceProvider('kaitlyn')).lastSeen, isNull);
  });

  test('presence is keyed per username, independent', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(presenceProvider('kaitlyn').notifier).set(true);
    expect(c.read(presenceProvider('kaitlyn')).online, isTrue);
    expect(c.read(presenceProvider('court')).online, isFalse);
  });
}
