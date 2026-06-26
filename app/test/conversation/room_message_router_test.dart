import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/incoming_banner_provider.dart';
import 'package:littlelove/conversation/message_content.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/conversation/presence_state.dart';
import 'package:littlelove/conversation/room_message_router.dart';
import 'package:littlelove/conversation/typing_state.dart';
import 'package:littlelove/audio/message_feedback.dart';
import 'package:littlelove/crypto/ecdh.dart';
import 'package:littlelove/identity/current_identity.dart';
import 'package:littlelove/identity/keypair.dart';
import 'package:littlelove/inbox/active_room_provider.dart';
import 'package:littlelove/inbox/inbox_state.dart';
import 'package:littlelove/inbox/room.dart';
import 'package:littlelove/outbox/outbox_store.dart';
import 'package:littlelove/pairing/encryption.dart';
import 'package:littlelove/wire/frames.dart';
import 'package:littlelove/wire/live_connection.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../outbox/memory_outbox_store.dart';

class _FakeConn implements LiveConnection {
  final _ctl = StreamController<RoomServerFrame>.broadcast();
  final List<Object> sent = [];

  @override
  Stream<RoomServerFrame> get incoming => _ctl.stream;
  @override
  void send(Object payload) => sent.add(payload);
  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async => _ctl.close();

  void emit(RoomServerFrame f) => _ctl.add(f);
}

/// Records calls instead of touching the native sound channel / haptics.
class _RecordingFeedback extends MessageFeedback {
  int sentCount = 0;
  int receivedCount = 0;
  @override
  void sent() => sentCount++;
  @override
  void received() => receivedCount++;
}

Future<MessageDb> _ffiMessageDb() async {
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: MessageDb.schemaVersion,
      onCreate: MessageDb.onCreate,
      onUpgrade: MessageDb.onUpgrade,
    ),
  );
  addTearDown(db.close);
  return MessageDb.test(db);
}

Future<ProviderContainer> _container({
  required LiveConnection conn,
  required DerivedIdentity me,
  OutboxStore? outbox,
  MessageDb? messageDb,
  List<Override> overrides = const [],
}) async {
  // The router write-through path resolves the message DB on every ingest, so
  // every test needs an in-memory one to avoid hitting the keychain/filesystem.
  final db = messageDb ?? await _ffiMessageDb();
  final container = ProviderContainer(
    overrides: [
      liveConnectionProvider.overrideWith((_) async => conn),
      currentIdentityProvider.overrideWith((_) async => me),
      messageDbProvider.overrideWith((_) async => db),
      if (outbox != null) outboxStoreProvider.overrideWith((_) async => outbox),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await container.read(liveConnectionProvider.future);
  await container.read(currentIdentityProvider.future);
  await container.read(messageDbProvider.future);
  if (outbox != null) await container.read(outboxStoreProvider.future);
  return container;
}

Member _member(String username, DerivedIdentity id) => Member(
  username: username,
  ed25519PubBase64: base64.encode(id.ed25519PublicKey),
  x25519PubBase64: base64.encode(id.x25519PublicKey),
);

/// Polls until [ready] is true, yielding to the event loop between checks.
///
/// Replaces fixed `Future.delayed` guesses: a frame kicks off async DB-backed
/// work (subscribe hydration, persistence), and a fixed delay that loses the
/// race lets the test body return so teardown closes the in-memory DB while
/// that work is still in flight — surfacing as a flaky `database_closed`. By
/// gating on the observable end-state instead, the awaited work is guaranteed
/// to have completed before we assert and before teardown tears the DB down.
Future<void> pumpUntil(
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!ready()) {
    if (sw.elapsed > timeout) {
      throw StateError('pumpUntil: condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// The room ids the fake connection has been asked to `Subscribe` to.
List<Object?> _sentOfKind(_FakeConn conn, String kind) => conn.sent
    .whereType<Map<String, Object?>>()
    .where((m) => m['kind'] == kind)
    .toList();

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final seedA = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final seedB = Uint8List.fromList(List<int>.generate(16, (i) => i + 101));

  test('Rooms frame populates inbox + subscribes', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomsFrame(
        rooms: [
          RoomDetail(
            roomId: 'room1',
            name: '',
            members: [_member('court', me), _member('kaitlyn', peer)],
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ],
      ),
    );
    // The Subscribe is the last step of the awaited subscribe path (after the
    // in-memory-DB hydration reads), so once it lands all DB work for this
    // frame has completed — no fixed-delay guess, no teardown race.
    await pumpUntil(() => _sentOfKind(conn, 'Subscribe').isNotEmpty);

    final inbox = container.read(inboxStateProvider);
    expect(inbox.rooms, hasLength(1));
    expect(inbox.rooms.single.roomId, 'room1');

    final subs = _sentOfKind(conn, 'Subscribe');
    expect(subs, hasLength(1));
    expect((subs.single as Map<String, Object?>)['room_id'], 'room1');
  });

  test(
    'Message decrypts using sender pubkey and lands in messageStore',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(roomMessageRouterProvider);

      // Encrypt as the peer would (their priv + my pub → same shared secret).
      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'm1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final msgs = container.read(messageStoreProvider('room1'));
      expect(msgs, hasLength(1));
      expect(msgs.single.body, 'hi love');
    },
  );

  test('tampered Message lands with body == cannotDecryptSentinel', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: 'not-a-valid-ciphertext',
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.body, cannotDecryptSentinel);
  });

  test('RoomCreated appends and subscribes', () async {
    final me = await deriveIdentity(seedA);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomCreatedFrame(
        roomId: 'room2',
        name: 'Travel',
        members: [_member('court', me)],
        pendingInvite: null,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(inboxStateProvider).rooms, hasLength(1));
    final subs = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'Subscribe')
        .toList();
    expect(subs.single['room_id'], 'room2');
  });

  test('RoomRenamed updates the inbox name', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    conn.emit(const RoomRenamedFrame(roomId: 'room1', name: 'Daily life'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(inboxStateProvider).rooms.single.name, 'Daily life');
  });

  test(
    'MemberLeft drops the member; room cascades when last member leaves',
    () async {
      final me = await deriveIdentity(seedA);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'solo',
          name: '',
          members: [_member('court', me)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(roomMessageRouterProvider);

      conn.emit(const MemberLeftFrame(roomId: 'solo', username: 'court'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Court was the only member → room cascades.
      expect(container.read(inboxStateProvider).rooms, isEmpty);
    },
  );

  test('ReadFrame flips matching messages in the store to read', () async {
    final me = await deriveIdentity(seedA);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    final store = container.read(messageStoreProvider('room1').notifier);
    for (final id in ['a', 'b']) {
      store.add(
        Msg(
          id: id,
          from: 'court',
          to: 'room1',
          body: 'x',
          ts: DateTime.utc(2026, 6, 10, 12),
        ),
      );
    }

    conn.emit(
      const ReadFrame(roomId: 'room1', messageIds: ['a'], reader: 'kaitlyn'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs.firstWhere((m) => m.id == 'a').sendStatus, SendStatus.read);
    expect(msgs.firstWhere((m) => m.id == 'b').sendStatus, SendStatus.sent);
  });

  test(
    'live partner message into the selected room sends a MarkRead',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(activeRoomProvider.notifier).state = 'room1';
      container.read(roomMessageRouterProvider);

      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'm1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final marks = conn.sent
          .cast<Map<String, Object?>>()
          .where((m) => m['kind'] == 'MarkRead')
          .toList();
      expect(marks, hasLength(1));
      expect(marks.single['room_id'], 'room1');
      expect(marks.single['up_to_message_id'], 'm1');
    },
  );

  test(
    'live partner message into a non-selected room sends no MarkRead',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      // No room selected.
      container.read(roomMessageRouterProvider);

      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'm1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final marks = conn.sent
          .cast<Map<String, Object?>>()
          .where((m) => m['kind'] == 'MarkRead')
          .toList();
      expect(marks, isEmpty);
    },
  );

  test('a replayed partner message into the selected room sends a debounced '
      'MarkRead', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(activeRoomProvider.notifier).state = 'room1';
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: true,
      ),
    );
    // Nothing fires synchronously — it's debounced.
    expect(
      conn.sent.cast<Map<String, Object?>>().where(
        (m) => m['kind'] == 'MarkRead',
      ),
      isEmpty,
    );
    // After the debounce window, exactly one MarkRead lands. This is what
    // keeps the server's unread_count (and thus the app-icon badge) from
    // sticking on messages the user has actually seen via replay.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final marks = conn.sent
        .cast<Map<String, Object?>>()
        .where((m) => m['kind'] == 'MarkRead')
        .toList();
    expect(marks, hasLength(1));
    expect(marks.single['up_to_message_id'], 'm1');
  });

  test(
    'a replayed partner message into a non-selected room sends no MarkRead',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      // No room selected — the debounce rechecks selection when it fires.
      container.read(roomMessageRouterProvider);

      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'm1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final marks = conn.sent
          .cast<Map<String, Object?>>()
          .where((m) => m['kind'] == 'MarkRead')
          .toList();
      expect(marks, isEmpty);
    },
  );

  test('a live partner message into a non-active room pops a banner', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    // Not viewing room1 (you're elsewhere / on the list).
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final banner = container.read(incomingBannerProvider);
    expect(banner, isNotNull);
    expect(banner!.roomId, 'room1');
    expect(banner.roomName, 'Date ideas');
    expect(banner.preview, 'hi love');
    expect(banner.msgId, 'm1');
  });

  test('no banner for a live message into the active room', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(activeRoomProvider.notifier).state = 'room1';
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(container.read(incomingBannerProvider), isNull);
  });

  test(
    'a live partner message in the active room plays the received cue',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final feedback = _RecordingFeedback();
      final container = await _container(
        conn: conn,
        me: me,
        overrides: [messageFeedbackProvider.overrideWithValue(feedback)],
      );

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: 'Date ideas',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(activeRoomProvider.notifier).state = 'room1';
      container.read(roomMessageRouterProvider);

      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'm1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
        ),
      );
      await pumpUntil(() => feedback.receivedCount > 0);

      expect(feedback.receivedCount, 1);
      expect(feedback.sentCount, 0);
    },
  );

  test('no received cue for a partner message in a non-active room', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final feedback = _RecordingFeedback();
    final container = await _container(
      conn: conn,
      me: me,
      overrides: [messageFeedbackProvider.overrideWithValue(feedback)],
    );

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    // No active room: you're on the list / elsewhere.
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    // The non-active path pops a banner *after* the awaited DB write, so wait
    // on the banner (not the store, which fills before that write) — otherwise
    // teardown closes the in-memory DB mid-upsert. Once it's set, the
    // received() decision has been made and skipped.
    await pumpUntil(() => container.read(incomingBannerProvider) != null);

    expect(feedback.receivedCount, 0);
  });

  test('no banner for a call-log entry in a non-active room', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    // A call ends → a CallContent log is emitted as a normal message. It must
    // not pop a "new message" banner in a room you're not viewing.
    final body = await encryptOutgoing(
      key,
      CallContent(
        callId: 'call-1',
        outcome: 'completed',
        durationS: 154,
        startedAt: DateTime.utc(2026, 6, 10, 12),
      ).encode(),
    );

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(container.read(incomingBannerProvider), isNull);
    // The call row itself still lands in the timeline.
    expect(container.read(messageStoreProvider('room1')), hasLength(1));
  });

  test('no received cue for a call-log entry in the active room', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final feedback = _RecordingFeedback();
    final container = await _container(
      conn: conn,
      me: me,
      overrides: [messageFeedbackProvider.overrideWithValue(feedback)],
    );

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(activeRoomProvider.notifier).state = 'room1';
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    // A call ends → a CallContent log lands while the room is open. It must not
    // chime/haptic like a real message (matches the banner exclusion).
    final body = await encryptOutgoing(
      key,
      CallContent(
        callId: 'call-1',
        outcome: 'completed',
        durationS: 154,
        startedAt: DateTime.utc(2026, 6, 10, 12),
      ).encode(),
    );

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    // markRoomRead runs in the same active-room branch, right after the chime
    // check, and sends a MarkRead — so once it lands the chime decision has
    // been made (and skipped). Gating on it avoids asserting too early.
    await pumpUntil(() => _sentOfKind(conn, 'MarkRead').isNotEmpty);

    expect(feedback.receivedCount, 0);
  });

  test('no banner for a replayed message', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hi love');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(container.read(incomingBannerProvider), isNull);
  });

  test('no banner for my own self-copy', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final outbox = MemoryOutboxStore();
    final container = await _container(conn: conn, me: me, outbox: outbox);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: 'Date ideas',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    // My own self-copy: encrypted to my own key, tagged with a clientMsgId.
    final key = await deriveRoomKey(
      me: me,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'miss you');

    conn.emit(
      MessageFrame(
        id: 'srv-1',
        roomId: 'room1',
        from: 'court',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
        clientMsgId: 'cli-1',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(container.read(incomingBannerProvider), isNull);
  });

  test('replayed self-copy with read:true lands as SendStatus.read', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    // My own self-copy: encrypted to my own key.
    final key = await deriveRoomKey(
      me: me,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'miss you');

    conn.emit(
      MessageFrame(
        id: 'srv-1',
        roomId: 'room1',
        from: 'court',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: true,
        read: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.sendStatus, SendStatus.read);
  });

  test('an inbound Typing frame flips the room typing flag', () async {
    final me = await deriveIdentity(seedA);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    expect(container.read(typingProvider('room1')), isFalse);

    conn.emit(
      const TypingFrame(roomId: 'room1', from: 'kaitlyn', typing: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(typingProvider('room1')), isTrue);

    conn.emit(
      const TypingFrame(roomId: 'room1', from: 'kaitlyn', typing: false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(typingProvider('room1')), isFalse);
  });

  test('an inbound Presence frame flips the partner online flag', () async {
    final me = await deriveIdentity(seedA);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);
    container.read(roomMessageRouterProvider);

    expect(container.read(presenceProvider('kaitlyn')).online, isFalse);

    conn.emit(const PresenceFrame(user: 'kaitlyn', online: true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(presenceProvider('kaitlyn')).online, isTrue);
    expect(container.read(presenceProvider('kaitlyn')).lastSeen, isNull);

    final seen = DateTime.utc(2026, 6, 24, 17);
    conn.emit(PresenceFrame(user: 'kaitlyn', online: false, lastSeen: seen));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(presenceProvider('kaitlyn')).online, isFalse);
    expect(container.read(presenceProvider('kaitlyn')).lastSeen, seen);
  });

  test('a live partner message clears the typing flag atomically', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    // Partner is typing.
    conn.emit(
      const TypingFrame(roomId: 'room1', from: 'kaitlyn', typing: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(typingProvider('room1')), isTrue);

    // Their message lands: typing must clear in the same pass, without waiting
    // on a separate Typing:false frame (which is what caused a double layout
    // change / flash).
    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    conn.emit(
      MessageFrame(
        id: 'm-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: await encryptOutgoing(key, const TextContent('hi').encode()),
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(container.read(typingProvider('room1')), isFalse);
    expect(container.read(messageStoreProvider('room1')).single.body, 'hi');
  });

  test(
    'an inbound reaction applies onto its target, not as a bubble',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      // A target message already in the timeline.
      container
          .read(messageStoreProvider('room1').notifier)
          .add(
            Msg(
              id: 'target-1',
              from: 'court',
              to: 'room1',
              body: 'hi love',
              ts: DateTime.utc(2026, 6, 10, 12),
            ),
          );
      container.read(roomMessageRouterProvider);

      final key = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(
        key,
        const ReactionContent(targetId: 'target-1', emoji: '❤️').encode(),
      );

      conn.emit(
        MessageFrame(
          id: 'reaction-1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12, 1),
          body: body,
          replayed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final msgs = container.read(messageStoreProvider('room1'));
      // No new bubble — still just the target, now carrying the reaction.
      expect(msgs, hasLength(1));
      expect(msgs.single.id, 'target-1');
      expect(msgs.single.reactions, {'kaitlyn': '❤️'});
    },
  );

  test('an inbound delete removes its target from the timeline', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final container = await _container(conn: conn, me: me);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container
        .read(messageStoreProvider('room1').notifier)
        .add(
          Msg(
            id: 'target-1',
            from: 'kaitlyn',
            to: 'room1',
            body: 'oops',
            ts: DateTime.utc(2026, 6, 10, 12),
          ),
        );
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(
      key,
      const DeleteContent(targetId: 'target-1').encode(),
    );

    conn.emit(
      MessageFrame(
        id: 'delete-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12, 1),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Target gone, and the delete itself produced no bubble.
    expect(container.read(messageStoreProvider('room1')), isEmpty);
  });

  test('an inbound edit rewrites its target, not as a bubble', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final messageDb = await _ffiMessageDb();
    final container = await _container(
      conn: conn,
      me: me,
      messageDb: messageDb,
    );

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    // The original message lands first (persisted to store + DB)...
    conn.emit(
      MessageFrame(
        id: 'target-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: await encryptOutgoing(
          key,
          const TextContent('helo love').encode(),
        ),
        replayed: false,
      ),
    );
    // ...then the author's edit of it.
    conn.emit(
      MessageFrame(
        id: 'edit-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12, 1),
        body: await encryptOutgoing(
          key,
          const EditContent(targetId: 'target-1', text: 'hello love').encode(),
        ),
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // No new bubble — still just the target, now carrying the edited text.
    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.id, 'target-1');
    expect(msgs.single.body, 'hello love');
    expect(msgs.single.edited, isTrue);

    // And the edit is persisted to the local projection.
    final persisted = (await messageDb.messagesFor('room1')).single;
    expect(persisted.body, 'hello love');
    expect(persisted.edited, isTrue);
  });

  test('an edit self-copy echo applies and drops its outbox row', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final outbox = MemoryOutboxStore();
    final selfPub = base64.encode(me.x25519PublicKey);
    await outbox.enqueue(
      clientMsgId: 'cli-edit',
      roomId: 'room1',
      bodies: {selfPub: 'ignored-ciphertext'},
    );
    final container = await _container(conn: conn, me: me, outbox: outbox);

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    // A target I authored, already in the timeline.
    container
        .read(messageStoreProvider('room1').notifier)
        .add(
          Msg(
            id: 'target-1',
            from: 'court',
            to: 'room1',
            body: 'helo',
            ts: DateTime.utc(2026, 6, 10, 12),
          ),
        );
    container.read(roomMessageRouterProvider);

    // My own edit self-copy: encrypted to my own key, tagged with clientMsgId.
    final key = await deriveRoomKey(
      me: me,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(
      key,
      const EditContent(targetId: 'target-1', text: 'hello').encode(),
    );
    conn.emit(
      MessageFrame(
        id: 'srv-edit',
        roomId: 'room1',
        from: 'court',
        ts: DateTime.utc(2026, 6, 10, 12, 1),
        body: body,
        replayed: false,
        clientMsgId: 'cli-edit',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Edit applied onto the target (no new bubble), and the outbox row is gone
    // so the drain won't resend it.
    final msgs = container.read(messageStoreProvider('room1'));
    expect(msgs, hasLength(1));
    expect(msgs.single.id, 'target-1');
    expect(msgs.single.body, 'hello');
    expect(await outbox.lookup('cli-edit'), isNull);
  });

  test(
    'a delete that replays before its target keeps the target hidden',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final container = await _container(conn: conn, me: me);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      container.read(roomMessageRouterProvider);

      final peerKey = await deriveRoomKey(
        me: peer,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      // Delete arrives first (target not yet in the buffer).
      conn.emit(
        MessageFrame(
          id: 'delete-1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12, 1),
          body: await encryptOutgoing(
            peerKey,
            const DeleteContent(targetId: 'target-1').encode(),
          ),
          replayed: false,
        ),
      );
      // Then the target itself lands — it must stay hidden.
      conn.emit(
        MessageFrame(
          id: 'target-1',
          roomId: 'room1',
          from: 'kaitlyn',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: await encryptOutgoing(
            peerKey,
            const TextContent('oops').encode(),
          ),
          replayed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(container.read(messageStoreProvider('room1')), isEmpty);
    },
  );

  test(
    'self-copy with clientMsgId reconciles the echo and drops the outbox row',
    () async {
      final me = await deriveIdentity(seedA);
      final peer = await deriveIdentity(seedB);
      final conn = _FakeConn();
      final outbox = MemoryOutboxStore();
      final selfPub = base64.encode(me.x25519PublicKey);
      await outbox.enqueue(
        clientMsgId: 'cli-1',
        roomId: 'room1',
        bodies: {selfPub: 'ignored-ciphertext'},
      );
      final container = await _container(conn: conn, me: me, outbox: outbox);

      container.read(inboxStateProvider.notifier).setRooms([
        Room(
          roomId: 'room1',
          name: '',
          members: [_member('court', me), _member('kaitlyn', peer)],
          createdAt: DateTime.utc(2026, 6, 10),
        ),
      ]);
      // Optimistic echo already on screen, keyed by the clientMsgId.
      container
          .read(messageStoreProvider('room1').notifier)
          .add(
            Msg(
              id: 'cli-1',
              from: 'court',
              to: 'room1',
              body: 'hi love',
              ts: DateTime.utc(2026, 6, 10, 12),
              clientMsgId: 'cli-1',
              sendStatus: SendStatus.sending,
            ),
          );
      container.read(roomMessageRouterProvider);

      // The server echoes our own self-copy: encrypted to our own pubkey
      // (ECDH of our key with itself), tagged with the originating clientMsgId.
      final key = await deriveRoomKey(
        me: me,
        peerX25519Pub: me.x25519PublicKey,
        roomId: 'room1',
      );
      final body = await encryptOutgoing(key, 'hi love');

      conn.emit(
        MessageFrame(
          id: 'srv-1',
          roomId: 'room1',
          from: 'court',
          ts: DateTime.utc(2026, 6, 10, 12),
          body: body,
          replayed: false,
          clientMsgId: 'cli-1',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Echo reconciled in place: id swapped to the authoritative server id.
      final msgs = container.read(messageStoreProvider('room1'));
      expect(msgs, hasLength(1));
      expect(msgs.single.id, 'srv-1');
      expect(msgs.single.body, 'hi love');

      // Outbox row dropped so the drain won't resend it.
      expect(await outbox.lookup('cli-1'), isNull);
    },
  );

  test('an ingested partner message is persisted to MessageDb', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final messageDb = await _ffiMessageDb();
    final container = await _container(
      conn: conn,
      me: me,
      messageDb: messageDb,
    );

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    final body = await encryptOutgoing(key, 'hello from partner');

    conn.emit(
      MessageFrame(
        id: 'm1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: body,
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final persisted = await messageDb.messagesFor('room1');
    expect(persisted.map((m) => m.body), contains('hello from partner'));
  });

  test('an inbound delete soft-deletes in MessageDb', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final messageDb = await _ffiMessageDb();
    final container = await _container(
      conn: conn,
      me: me,
      messageDb: messageDb,
    );

    container.read(inboxStateProvider.notifier).setRooms([
      Room(
        roomId: 'room1',
        name: '',
        members: [_member('court', me), _member('kaitlyn', peer)],
        createdAt: DateTime.utc(2026, 6, 10),
      ),
    ]);
    container.read(roomMessageRouterProvider);

    final key = await deriveRoomKey(
      me: peer,
      peerX25519Pub: me.x25519PublicKey,
      roomId: 'room1',
    );
    // Ingest a message, then a delete naming it.
    conn.emit(
      MessageFrame(
        id: 'target-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12),
        body: await encryptOutgoing(key, const TextContent('oops').encode()),
        replayed: false,
      ),
    );
    conn.emit(
      MessageFrame(
        id: 'delete-1',
        roomId: 'room1',
        from: 'kaitlyn',
        ts: DateTime.utc(2026, 6, 10, 12, 1),
        body: await encryptOutgoing(
          key,
          const DeleteContent(targetId: 'target-1').encode(),
        ),
        replayed: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await messageDb.messagesFor('room1'), isEmpty);
  });

  test('subscribe hydrates the store from MessageDb and sends HWM as '
      'sinceMessageId', () async {
    final me = await deriveIdentity(seedA);
    final peer = await deriveIdentity(seedB);
    final conn = _FakeConn();
    final messageDb = await _ffiMessageDb();
    // Pre-seed two persisted rows for room1 (cold-launch local history).
    for (final id in ['01A', '01B']) {
      await messageDb.upsert(
        Msg(
          id: id,
          from: 'kaitlyn',
          to: 'room1',
          body: 'cached $id',
          ts: DateTime.utc(2026, 6, 10, 12),
        ),
        roomId: 'room1',
      );
    }
    final container = await _container(
      conn: conn,
      me: me,
      messageDb: messageDb,
    );
    container.read(roomMessageRouterProvider);

    conn.emit(
      RoomsFrame(
        rooms: [
          RoomDetail(
            roomId: 'room1',
            name: '',
            members: [_member('court', me), _member('kaitlyn', peer)],
            createdAt: DateTime.utc(2026, 6, 10),
          ),
        ],
      ),
    );
    // Subscribe is sent after the store is hydrated and the high-water-mark is
    // read, so gating on it guarantees both DB reads finished before we assert
    // (and before teardown closes the DB) — same race as the rooms test above.
    await pumpUntil(() => _sentOfKind(conn, 'Subscribe').isNotEmpty);

    // Store hydrated from the DB.
    expect(container.read(messageStoreProvider('room1')).map((m) => m.id), [
      '01A',
      '01B',
    ]);
    // Subscribe carried the high-water-mark as the delta anchor.
    final subs = _sentOfKind(conn, 'Subscribe');
    expect((subs.single as Map<String, Object?>)['since_message_id'], '01B');
  });
}
