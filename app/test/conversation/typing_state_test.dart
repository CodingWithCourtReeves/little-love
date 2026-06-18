import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/typing_state.dart';

void main() {
  test('defaults to not typing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(typingProvider('room1')), isFalse);
  });

  test('setTyping(true) then (false) flips the flag', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(typingProvider('room1').notifier);

    notifier.setTyping(true);
    expect(container.read(typingProvider('room1')), isTrue);

    notifier.setTyping(false);
    expect(container.read(typingProvider('room1')), isFalse);
  });

  test('typing auto-clears after the safety timeout if no stop arrives', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(typingProvider('room1').notifier);

      notifier.setTyping(true);
      expect(container.read(typingProvider('room1')), isTrue);

      // Still typing just before the timeout…
      async.elapse(const Duration(seconds: 5));
      expect(container.read(typingProvider('room1')), isTrue);

      // …and cleared once the 6s timeout elapses.
      async.elapse(const Duration(seconds: 2));
      expect(container.read(typingProvider('room1')), isFalse);
    });
  });

  test('a refresh before timeout keeps the indicator alive', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(typingProvider('room1').notifier);

      notifier.setTyping(true);
      async.elapse(const Duration(seconds: 5));
      // A fresh typing frame resets the timer.
      notifier.setTyping(true);
      async.elapse(const Duration(seconds: 5));
      expect(container.read(typingProvider('room1')), isTrue);
    });
  });
}
