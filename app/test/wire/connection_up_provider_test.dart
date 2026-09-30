import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/live_connection.dart';

/// Stands in for an open socket; the provider only checks that one exists.
class _FakeConn implements LiveConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test('a live socket reads as up', () async {
    final c = ProviderContainer(
      overrides: [
        liveConnectionProvider.overrideWith((_) async => _FakeConn()),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(connectionUpProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(liveConnectionProvider.future);
    expect(c.read(connectionUpProvider), isTrue);
  });

  test('a reconnect after a drop reads as down, even though Riverpod keeps '
      'the dead socket as AsyncData(isLoading: true)', () async {
    var builds = 0;
    final reconnect = Completer<LiveConnection>();
    final c = ProviderContainer(
      overrides: [
        liveConnectionProvider.overrideWith((ref) {
          builds++;
          // First build connects; the rebuild after the drop hangs in the
          // backoff loop until the server is reachable again.
          return builds == 1 ? Future.value(_FakeConn()) : reconnect.future;
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(connectionUpProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(liveConnectionProvider.future);
    expect(c.read(connectionUpProvider), isTrue);

    // What `conn.closed` → `ref.invalidateSelf()` does: a seamless refresh.
    c.invalidate(liveConnectionProvider);
    final state = c.read(liveConnectionProvider);
    expect(state, isA<AsyncData<LiveConnection>>());
    expect(state.isLoading, isTrue);
    expect(c.read(connectionUpProvider), isFalse);

    reconnect.complete(_FakeConn());
    await c.read(liveConnectionProvider.future);
    expect(c.read(connectionUpProvider), isTrue);
  });
}
