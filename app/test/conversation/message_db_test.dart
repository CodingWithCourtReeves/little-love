import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/conversation/composer_draft.dart';
import 'package:littlelove/conversation/link_preview.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/reply_ref.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<MessageDb> freshDb() async {
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

  Msg msg(String id, {String body = 'hello', String from = 'alice'}) => Msg(
    id: id,
    from: from,
    to: 'room1',
    body: body,
    ts: DateTime.utc(2026, 6, 24, 12),
  );

  test('upsert then read back, ordered by id ascending', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'first'), roomId: 'room1');
    await db.upsert(msg('01B', body: 'second'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.map((m) => m.body), ['first', 'second']);
  });

  test('upsert is idempotent on id', () async {
    final db = await freshDb();
    await db.upsert(msg('01A', body: 'v1'), roomId: 'room1');
    await db.upsert(msg('01A', body: 'v2'), roomId: 'room1');
    final rows = await db.messagesFor('room1');
    expect(rows.length, 1);
  });

  test('messagesFor scopes by room', () async {
    final db = await freshDb();
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room2');
    expect((await db.messagesFor('room1')).length, 1);
    expect((await db.messagesFor('room2')).length, 1);
  });

  test('reconcile swaps the optimistic row for the server id, keeping '
      'clientMsgId', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: 'cmid-1',
        from: 'alice',
        to: 'room1',
        body: 'hi',
        ts: DateTime.utc(2026),
        clientMsgId: 'cmid-1',
        sendStatus: SendStatus.sending,
      ),
      roomId: 'room1',
    );
    await db.reconcile(
      'cmid-1',
      Msg(
        id: '01SERVER',
        from: 'alice',
        to: 'room1',
        body: 'hi',
        ts: DateTime.utc(2026),
      ),
    );
    final rows = await db.messagesFor('room1');
    expect(rows.single.id, '01SERVER');
    expect(rows.single.clientMsgId, 'cmid-1');
  });

  test('applyDelete soft-deletes and stays sticky for an out-of-order '
      'target', () async {
    final db = await freshDb();
    // Delete arrives first (target not yet stored).
    await db.applyDelete('01X', requestedBy: 'alice');
    // Target arrives later, authored by alice — must stay suppressed.
    await db.upsert(
      Msg(
        id: '01X',
        from: 'alice',
        to: 'room1',
        body: 'gone',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    expect(await db.messagesFor('room1'), isEmpty);
  });

  test(
    'applyDelete rejects a spoofed delete (requestedBy != author)',
    () async {
      final db = await freshDb();
      await db.upsert(
        Msg(
          id: '01Y',
          from: 'alice',
          to: 'room1',
          body: 'mine',
          ts: DateTime.utc(2026),
        ),
        roomId: 'room1',
      );
      await db.applyDelete(
        '01Y',
        requestedBy: 'bob',
      ); // bob can't unsend alice's
      expect((await db.messagesFor('room1')).length, 1);
    },
  );

  test('markRead promotes send_status to read', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01Z',
        from: 'me',
        to: 'room1',
        body: 'seen?',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await db.markRead(['01Z']);
    expect((await db.messagesFor('room1')).single.sendStatus, SendStatus.read);
  });

  test('applyReaction stores and toggles off', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01R',
        from: 'alice',
        to: 'room1',
        body: 'react me',
        ts: DateTime.utc(2026),
      ),
      roomId: 'room1',
    );
    await db.applyReaction('01R', 'bob', '❤️');
    expect((await db.messagesFor('room1')).single.reactions, {'bob': '❤️'});
    await db.applyReaction('01R', 'bob', '');
    expect((await db.messagesFor('room1')).single.reactions, isEmpty);
  });

  test('applyEdit rewrites the body and marks it edited', () async {
    final db = await freshDb();
    await db.upsert(msg('01E', body: 'teh typo'), roomId: 'room1');

    await db.applyEdit('01E', requestedBy: 'alice', text: 'the typo');

    final out = (await db.messagesFor('room1')).single;
    expect(out.body, 'the typo');
    expect(out.edited, isTrue);
  });

  test('applyEdit sets and clears the link preview', () async {
    final db = await freshDb();
    await db.upsert(msg('01E', body: 'plain'), roomId: 'room1');

    const preview = LinkPreview(
      url: 'https://example.com',
      title: 'T',
      description: 'D',
      siteName: 'S',
      imageB64: null,
      imageWidth: null,
      imageHeight: null,
    );
    await db.applyEdit(
      '01E',
      requestedBy: 'alice',
      text: 'see https://example.com',
      preview: preview,
    );
    expect((await db.messagesFor('room1')).single.linkPreview?.title, 'T');

    await db.applyEdit('01E', requestedBy: 'alice', text: 'never mind');
    expect((await db.messagesFor('room1')).single.linkPreview, isNull);
  });

  test('applyEdit rejects a spoofed edit (requestedBy != author)', () async {
    final db = await freshDb();
    await db.upsert(
      msg('01E', body: 'mine', from: 'alice'),
      roomId: 'room1',
    );

    await db.applyEdit('01E', requestedBy: 'bob', text: 'hijacked');

    final out = (await db.messagesFor('room1')).single;
    expect(out.body, 'mine');
    expect(out.edited, isFalse);
  });

  test('an edit that arrives before its target applies on upsert', () async {
    final db = await freshDb();
    // Edit lands first (target not yet stored).
    await db.applyEdit('01G', requestedBy: 'alice', text: 'the fix');
    expect(await db.messagesFor('room1'), isEmpty);

    // Target arrives later, authored by alice — the edit must apply.
    await db.upsert(
      msg('01G', body: 'teh fix', from: 'alice'),
      roomId: 'room1',
    );
    final out = (await db.messagesFor('room1')).single;
    expect(out.body, 'the fix');
    expect(out.edited, isTrue);
  });

  test('a spoofed edit before its target is dropped when it lands', () async {
    final db = await freshDb();
    // Edit names bob as editor, but the target is authored by alice.
    await db.applyEdit('01H', requestedBy: 'bob', text: 'hijacked');
    await db.upsert(
      msg('01H', body: 'mine', from: 'alice'),
      roomId: 'room1',
    );

    final out = (await db.messagesFor('room1')).single;
    expect(out.body, 'mine');
    expect(out.edited, isFalse);
  });

  test('the edited flag survives an upsert round-trip', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01F',
        from: 'alice',
        to: 'room1',
        body: 'already fixed',
        ts: DateTime.utc(2026),
        edited: true,
      ),
      roomId: 'room1',
    );
    expect((await db.messagesFor('room1')).single.edited, isTrue);
  });

  test('highWaterMark returns the max stored id per room, null when '
      'empty', () async {
    final db = await freshDb();
    expect(await db.highWaterMark('room1'), isNull);
    await db.upsert(msg('01A'), roomId: 'room1');
    await db.upsert(msg('01C'), roomId: 'room1');
    await db.upsert(msg('01B'), roomId: 'room1');
    expect(await db.highWaterMark('room1'), '01C');
  });

  test('persists and reloads replyTo', () async {
    final db = await freshDb();
    await db.upsert(
      Msg(
        id: '01A',
        from: 'court',
        to: 'room1',
        body: 'hi',
        ts: DateTime.utc(2026, 6, 24, 12),
        replyTo: const ReplyRef(id: 'orig', author: 'kaitlyn', kind: 'photo'),
      ),
      roomId: 'room1',
    );
    final rows = await db.messagesFor('room1');
    expect(rows.single.replyTo!.id, 'orig');
    expect(rows.single.replyTo!.kind, 'photo');
  });

  test('a row without replyTo reloads as null', () async {
    final db = await freshDb();
    await db.upsert(msg('01A'), roomId: 'room1');
    expect((await db.messagesFor('room1')).single.replyTo, isNull);
  });

  group('composer drafts', () {
    const reply = ReplyRef(
      id: '01Q',
      author: 'kaitlyn',
      kind: 'text',
      text: 'dinner?',
    );

    test('a room with no saved draft reads back null', () async {
      final db = await freshDb();
      expect(await db.draftFor('room1'), isNull);
    });

    test('saveDraft round-trips text and the quoted reply', () async {
      final db = await freshDb();
      await db.saveDraft(
        'room1',
        const ComposerDraft(text: 'yes, 7pm', replyTo: reply),
      );
      final d = await db.draftFor('room1');
      expect(d!.text, 'yes, 7pm');
      expect(d.replyTo!.id, '01Q');
      expect(d.replyTo!.text, 'dinner?');
    });

    test('saveDraft overwrites the previous draft for the room', () async {
      final db = await freshDb();
      await db.saveDraft('room1', const ComposerDraft(text: 'first'));
      await db.saveDraft('room1', const ComposerDraft(text: 'second'));
      final d = await db.draftFor('room1');
      expect(d!.text, 'second');
      expect(d.replyTo, isNull);
    });

    test('drafts are scoped per room', () async {
      final db = await freshDb();
      await db.saveDraft('room1', const ComposerDraft(text: 'one'));
      await db.saveDraft('room2', const ComposerDraft(text: 'two'));
      expect((await db.draftFor('room1'))!.text, 'one');
      expect((await db.draftFor('room2'))!.text, 'two');
    });

    test('saving an empty draft deletes the stored one', () async {
      final db = await freshDb();
      await db.saveDraft('room1', const ComposerDraft(text: 'typing'));
      await db.saveDraft('room1', const ComposerDraft(text: '   '));
      expect(await db.draftFor('room1'), isNull);
    });

    test('a reply with no text is still a draft worth keeping', () async {
      final db = await freshDb();
      await db.saveDraft(
        'room1',
        const ComposerDraft(text: '', replyTo: reply),
      );
      expect((await db.draftFor('room1'))!.replyTo!.id, '01Q');
    });

    test(
      'a downgrade then re-upgrade reopens cleanly (drafts table kept)',
      () async {
        final raw = await databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: MessageDb.schemaVersion,
            onCreate: MessageDb.onCreate,
          ),
        );
        addTearDown(raw.close);
        await MessageDb.test(
          raw,
        ).saveDraft('room1', const ComposerDraft(text: 'kept'));
        // An older build opening the store only rewinds user_version.
        await raw.setVersion(4);
        await MessageDb.onUpgrade(raw, 4, MessageDb.schemaVersion);
        expect((await MessageDb.test(raw).draftFor('room1'))!.text, 'kept');
      },
    );

    test('a restored draft drops its reply chip once the quoted message was '
        'unsent by its author', () async {
      final db = await freshDb();
      await db.upsert(
        msg('01Q', body: 'dinner?', from: 'kaitlyn'),
        roomId: 'room1',
      );
      await db.saveDraft(
        'room1',
        const ComposerDraft(text: 'yes', replyTo: reply),
      );
      await db.applyDelete('01Q', requestedBy: 'kaitlyn');
      final d = await db.draftFor('room1');
      expect(d!.text, 'yes');
      expect(d.replyTo, isNull);
    });

    test('a spoofed tombstone (not the author) does not drop the reply '
        'chip', () async {
      final db = await freshDb();
      await db.saveDraft(
        'room1',
        const ComposerDraft(text: 'yes', replyTo: reply),
      );
      // Target not stored locally, so the tombstone is recorded; its
      // requester is not the quoted message's author.
      await db.applyDelete('01Q', requestedBy: 'mallory');
      expect((await db.draftFor('room1'))!.replyTo!.id, '01Q');
    });

    test('a reply-only draft whose target was unsent reads back as no '
        'draft', () async {
      final db = await freshDb();
      await db.saveDraft(
        'room1',
        const ComposerDraft(text: '', replyTo: reply),
      );
      await db.applyDelete('01Q', requestedBy: 'kaitlyn');
      expect(await db.draftFor('room1'), isNull);
    });

    test('clear wipes drafts (sign-out)', () async {
      final db = await freshDb();
      await db.saveDraft('room1', const ComposerDraft(text: 'secret'));
      await db.clear();
      expect(await db.draftFor('room1'), isNull);
    });
  });
}
