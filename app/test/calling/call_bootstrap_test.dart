import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/calling/call_bootstrap.dart';
import 'package:littlelove/calling/call_controller.dart';
import 'package:littlelove/conversation/room_message_router.dart';
import 'package:littlelove/identity/providers.dart';
import 'package:littlelove/inbox/read_state_provider.dart';
import 'package:littlelove/inbox/read_state_store.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeConn implements LiveConnection {
  final _closed = Completer<void>();
  final _incoming = StreamController<RoomServerFrame>.broadcast();

  void drop() => _closed.complete();

  void emit(RoomServerFrame frame) => _incoming.add(frame);

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

  // The server sends the room list once per connection, right after the
  // handshake. A router that isn't listening at that moment misses it for good,
  // and the home screen stays blank until the socket reconnects.
  group('the real router hears frames as soon as the socket is up', () {
    final readUpTo = DateTime.utc(2026, 11, 4, 12);
    var allowReconnect = false;
    setUp(() => allowReconnect = false);

    Future<(ProviderContainer, List<_FakeConn>)> mountWithoutFrames(
      WidgetTester tester, {
      bool failReconnect = false,
    }) async {
      final tmp = Directory.systemTemp.createTempSync('call_bootstrap');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final conns = <_FakeConn>[];
      final container = ProviderContainer(
        overrides: [
          readStateStoreProvider.overrideWithValue(
            ReadStateStore(homeDirectory: tmp),
          ),
          liveConnectionProvider.overrideWith((ref) async {
            if (failReconnect && !allowReconnect && conns.isNotEmpty) {
              throw StateError('signed out');
            }
            final conn = _FakeConn();
            conns.add(conn);
            unawaited(conn.closed.then((_) => ref.invalidateSelf()));
            return conn;
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
      return (container, conns);
    }

    testWidgets('with no frame drawn, as behind the Face ID prompt', (
      tester,
    ) async {
      final (container, conns) = await mountWithoutFrames(tester);

      conns.single.emit(ReadMarkerFrame(roomId: 'r', readUpTo: readUpTo));
      await tester.idle();

      expect(container.read(readStateProvider)['r'], readUpTo);
    });

    testWidgets('after a reconnect, on the new socket', (tester) async {
      final (container, conns) = await mountWithoutFrames(tester);

      conns.first.drop();
      await tester.idle();
      expect(conns, hasLength(2));

      conns.last.emit(ReadMarkerFrame(roomId: 'r', readUpTo: readUpTo));
      await tester.idle();

      expect(container.read(readStateProvider)['r'], readUpTo);
    });

    testWidgets('after a failed connection recovers, on the new socket', (
      tester,
    ) async {
      final (container, conns) = await mountWithoutFrames(
        tester,
        failReconnect: true,
      );

      conns.single.drop();
      await tester.idle();
      expect(container.read(liveConnectionProvider).hasError, isTrue);

      allowReconnect = true;
      container.invalidate(liveConnectionProvider);
      container.read(liveConnectionProvider);
      await tester.idle();
      expect(conns, hasLength(2));

      conns.last.emit(ReadMarkerFrame(roomId: 'r', readUpTo: readUpTo));
      await tester.idle();

      expect(container.read(readStateProvider)['r'], readUpTo);
    });

    testWidgets('a failed connection stops the router hearing the old socket', (
      tester,
    ) async {
      final (container, conns) = await mountWithoutFrames(
        tester,
        failReconnect: true,
      );

      conns.single.drop();
      await tester.idle();

      conns.single.emit(ReadMarkerFrame(roomId: 'r', readUpTo: readUpTo));
      await tester.idle();

      expect(container.read(readStateProvider)['r'], isNull);
    });
  });
}
