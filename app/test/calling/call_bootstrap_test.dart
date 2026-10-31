import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_bootstrap.dart';
import 'package:littlelove/calling/call_controller.dart';
import 'package:littlelove/conversation/room_message_router.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeConn implements LiveConnection {
  final _closed = Completer<void>();
  final _incoming = StreamController<RoomServerFrame>.broadcast();

  void drop() => _closed.complete();

  @override
  Future<void> get closed => _closed.future;

  @override
  Stream<RoomServerFrame> get incoming => _incoming.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeRouter implements RoomMessageRouter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  // A VoIP push can wake the app in the background, where iOS draws no frames.
  // Riverpod only refreshes a mounted scope's providers inside a build, so the
  // call stack must start, and reconnect, without one. These tests mount the
  // scope and never pump a frame after it.
  testWidgets('starts and reconnects the call stack without a frame', (
    tester,
  ) async {
    final conns = <_FakeConn>[];
    var routers = 0;
    final container = ProviderContainer(
      overrides: [
        liveConnectionProvider.overrideWith((ref) async {
          final conn = _FakeConn();
          conns.add(conn);
          unawaited(conn.closed.then((_) => ref.invalidateSelf()));
          return conn;
        }),
        roomMessageRouterProvider.overrideWith((ref) {
          ref.watch(liveConnectionProvider).requireValue;
          routers++;
          return _FakeRouter();
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    keepCallStackRunning(container);
    await tester.idle();

    expect(container.exists(callControllerProvider), isTrue);
    expect(conns, hasLength(1));
    expect(routers, 1);

    conns.first.drop();
    await tester.idle();

    expect(conns, hasLength(2), reason: 'reconnected with no frame drawn');
    expect(routers, 2, reason: 'the router moved to the new socket');
  });
}
