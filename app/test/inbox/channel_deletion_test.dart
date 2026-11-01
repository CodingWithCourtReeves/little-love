import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/inbox/channel_deletion.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';

class _FakeConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Map<String, Object?>> sent = [];

  /// Frames to emit in reply to the next send, simulating the server.
  List<RoomServerFrame> reply = const [];

  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) {
    sent.add(payload as Map<String, Object?>);
    for (final f in reply) {
      scheduleMicrotask(() => _ctl.add(f));
    }
  }

  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async => _ctl.close();
}

void main() {
  group('channelNameMatches', () {
    test('ignores case and surrounding spaces', () {
      expect(channelNameMatches('travel', 'Travel'), isTrue);
      expect(channelNameMatches('  Travel ', 'Travel'), isTrue);
    });

    test('a partial or different name does not match', () {
      expect(channelNameMatches('Trave', 'Travel'), isFalse);
      expect(channelNameMatches('', 'Travel'), isFalse);
    });

    test('an emoji in the name must be typed', () {
      expect(channelNameMatches('Trips', 'Trips ✈️'), isFalse);
      expect(channelNameMatches('trips ✈️', 'Trips ✈️'), isTrue);
    });
  });

  group('requestChannelDeletion', () {
    test('no connection is offline, and nothing is sent', () async {
      expect(
        await requestChannelDeletion(conn: null, roomId: 'chan'),
        DeleteChannelOutcome.offline,
      );
    });

    test('RoomDeleted for the room is deleted', () async {
      final conn = _FakeConn()
        ..reply = const [RoomDeletedFrame(roomId: 'chan', deletedBy: 'court')];
      expect(
        await requestChannelDeletion(conn: conn, roomId: 'chan'),
        DeleteChannelOutcome.deleted,
      );
      expect(conn.sent.single, {'kind': 'DeleteRoom', 'room_id': 'chan'});
    });

    test(
      'UnknownRoom for the room counts as deleted (both deleted at once)',
      () async {
        final conn = _FakeConn()
          ..reply = const [
            RoomErrorFrame(code: 'UnknownRoom', message: '', roomId: 'chan'),
          ];
        expect(
          await requestChannelDeletion(conn: conn, roomId: 'chan'),
          DeleteChannelOutcome.deleted,
        );
      },
    );

    test('another error for the room is failed', () async {
      final conn = _FakeConn()
        ..reply = const [
          RoomErrorFrame(code: 'RateLimited', message: '', roomId: 'chan'),
        ];
      expect(
        await requestChannelDeletion(conn: conn, roomId: 'chan'),
        DeleteChannelOutcome.failed,
      );
    });

    test('errors about other requests are not this delete\'s result', () async {
      final conn = _FakeConn()
        ..reply = const [
          RoomErrorFrame(code: 'UnknownRoom', message: ''),
          RoomErrorFrame(code: 'RateLimited', message: '', roomId: 'other'),
          RoomDeletedFrame(roomId: 'other', deletedBy: 'court'),
          RoomDeletedFrame(roomId: 'chan', deletedBy: 'court'),
        ];
      expect(
        await requestChannelDeletion(conn: conn, roomId: 'chan'),
        DeleteChannelOutcome.deleted,
      );
    });

    test('no answer within the timeout is failed', () {
      fakeAsync((async) {
        DeleteChannelOutcome? outcome;
        requestChannelDeletion(
          conn: _FakeConn(),
          roomId: 'chan',
          timeout: const Duration(seconds: 10),
        ).then((o) => outcome = o);
        async.elapse(const Duration(seconds: 9));
        expect(outcome, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(outcome, DeleteChannelOutcome.failed);
      });
    });
  });
}
