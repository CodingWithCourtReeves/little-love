import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/channel/channel_picture.dart';
import 'package:littlelove/channel/channel_picture_provider.dart';
import 'package:littlelove/conversation/message_content.dart';
import 'package:littlelove/conversation/message_db.dart';
import 'package:littlelove/conversation/message_store.dart';
import 'package:littlelove/wire/message.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Msg update(
  String id,
  ChannelPicture picture, {
  int ts = 1,
  SendStatus status = SendStatus.sent,
}) => Msg(
  id: id,
  from: 'court',
  to: 'room1',
  body: '',
  ts: DateTime.utc(2026, 6, 24, 12, 0, ts),
  sendStatus: status,
  channelUpdate: ChannelUpdateContent(picture: picture),
);

const heart = SymbolPicture(ChannelSymbol.heart, ChannelColor.rose);
const moon = SymbolPicture(ChannelSymbol.moon, ChannelColor.sky);

void main() {
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  MessageStore store() =>
      container.read(messageStoreProvider('room1').notifier);
  ChannelPicture? current() =>
      container.read(currentChannelPictureProvider('room1'));

  test('no channel updates means no picture', () {
    expect(current(), isNull);
  });

  test('latest wins by ts then id even when arrival order differs', () {
    store().add(update('01B', moon, ts: 2));
    store().add(update('01A', heart, ts: 1));
    expect(current(), same(moon));

    store().add(update('01C', heart, ts: 3));
    store().add(update('01D', moon, ts: 3));
    expect(current(), same(moon));
  });

  test('a failed optimistic change does not replace the current picture', () {
    store().add(update('01A', heart, ts: 1));
    store().add(update('01B', moon, ts: 2, status: SendStatus.failed));
    expect(current(), same(heart));
  });

  test('removing the picture returns null', () {
    store().add(update('01A', heart, ts: 1));
    store().add(update('01B', const NoPicture(), ts: 2));
    expect(current(), isNull);
  });

  test('an unrecognised picture still counts as the current picture', () {
    store().add(update('01A', const UnknownPicture({'type': 'x'})));
    expect(current(), isA<UnknownPicture>());
  });

  test('the picture survives a hydrate from the cache', () async {
    sqfliteFfiInit();
    final raw = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: MessageDb.schemaVersion,
        onCreate: MessageDb.onCreate,
        onUpgrade: MessageDb.onUpgrade,
      ),
    );
    addTearDown(raw.close);
    final db = MessageDb.test(raw);
    await db.upsert(update('01A', heart, ts: 1), roomId: 'room1');
    await db.upsert(update('01B', moon, ts: 2), roomId: 'room1');
    store().setAll(await db.messagesFor('room1'));
    final pic = current();
    expect(pic, isA<SymbolPicture>());
    expect((pic! as SymbolPicture).symbol, ChannelSymbol.moon);
  });

  test('a non-photo picture yields no photo file and no network use', () async {
    store().add(update('01A', heart));
    expect(
      await container.read(channelPhotoFileProvider('room1').future),
      isNull,
    );
  });
}
