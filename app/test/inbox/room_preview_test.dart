import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';
import 'package:littlelove/conversation/status_marker.dart';
import 'package:littlelove/inbox/room_preview.dart';
import 'package:littlelove/pairing/encryption.dart';
import 'package:littlelove/wire/message.dart';

Msg _msg(
  String id,
  String from,
  String body, {
  int minute = 0,
  SendStatus status = SendStatus.sent,
  AttachmentDescriptor? attachment,
  String? callOutcome,
}) => Msg(
  id: id,
  from: from,
  to: 'room1',
  body: body,
  ts: DateTime.utc(2026, 10, 29, 20, minute),
  sendStatus: status,
  attachment: attachment,
  callOutcome: callOutcome,
);

AttachmentDescriptor _file(String mime, {int? durationMs}) =>
    AttachmentDescriptor(
      blobKey: 'b',
      contentKeyB64: 'k',
      nonceB64: 'n',
      mime: mime,
      filename: 'f',
      size: 1,
      width: 1,
      height: 1,
      durationMs: durationMs,
      thumbB64: '',
    );

RoomPreview _preview(
  List<Msg> messages, {
  bool hydrated = true,
  int unread = 0,
  bool typing = false,
  String? draft,
}) => roomPreviewFor(
  messages: messages,
  me: 'court',
  hydrated: hydrated,
  unread: unread,
  partnerTyping: typing,
  draft: draft,
);

void main() {
  test(
    'the newest message by time is the preview, not the last in the list',
    () {
      final p = _preview([
        _msg('2', 'kaitlyn', 'newer', minute: 30),
        _msg('1', 'kaitlyn', 'older', minute: 10),
      ]);
      expect(p.text, 'newer');
      expect(p.at, DateTime.utc(2026, 10, 29, 20, 30));
    },
  );

  test("my latest message gets You: and its bubble's delivery mark", () {
    for (final (status, mark) in [
      (SendStatus.sending, StatusMark.sending),
      (SendStatus.sent, StatusMark.sent),
      (SendStatus.read, StatusMark.read),
    ]) {
      final p = _preview([_msg('1', 'court', 'hi', status: status)]);
      expect(p.fromMe, isTrue);
      expect(p.mark, mark);
      expect(p.failed, isFalse);
    }
  });

  test('a failed send shows the failed mark instead of a heart', () {
    final p = _preview([
      _msg('1', 'court', 'move it to 8?', status: SendStatus.failed),
    ]);
    expect(p.failed, isTrue);
    expect(p.mark, isNull);
    expect(p.fromMe, isTrue);
  });

  test("my partner's latest message has no prefix and no mark", () {
    final p = _preview([_msg('1', 'kaitlyn', 'love you')]);
    expect(p.fromMe, isFalse);
    expect(p.mark, isNull);
  });

  test('partner typing beats a draft, which beats the latest message; the '
      'time stays the latest message', () {
    final msgs = [_msg('1', 'kaitlyn', 'hi', minute: 5)];
    final typing = _preview(msgs, typing: true, draft: 'oat milk');
    expect(typing.text, 'typing…');
    expect(typing.tone, PreviewTone.live);
    expect(typing.at, DateTime.utc(2026, 10, 29, 20, 5));

    final drafted = _preview(msgs, draft: 'oat milk');
    expect(drafted.text, 'oat milk');
    expect(drafted.isDraft, isTrue);
    expect(drafted.at, DateTime.utc(2026, 10, 29, 20, 5));
  });

  test('an empty room reads "No messages yet" only once its history has '
      'loaded', () {
    final loading = _preview(const [], hydrated: false);
    expect(loading.text, isEmpty);
    expect(loading.at, isNull);

    final empty = _preview(const []);
    expect(empty.text, 'No messages yet');
    expect(empty.tone, PreviewTone.placeholder);
  });

  test(
    'a message this phone could not decrypt reads "Message unavailable"',
    () {
      final p = _preview([_msg('1', 'kaitlyn', cannotDecryptSentinel)]);
      expect(p.text, 'Message unavailable');
      expect(p.tone, PreviewTone.placeholder);
    },
  );

  test('a missed call reads as a warning, without the leading emoji', () {
    final p = _preview([
      _msg('1', 'kaitlyn', '📹 Missed video call', callOutcome: 'missed'),
    ]);
    expect(p.text, 'Missed video call');
    expect(p.icon, PreviewIcon.call);
    expect(p.tone, PreviewTone.warning);
    expect(p.fromMe, isFalse);
  });

  test('a completed call reads plainly', () {
    final p = _preview([
      _msg('1', 'court', '📞 Call · 4:02', callOutcome: 'completed'),
    ]);
    expect(p.text, 'Call · 4:02');
    expect(p.tone, PreviewTone.plain);
    expect(p.mark, isNull);
  });

  test('media previews: the caption when there is one, else its kind', () {
    expect(
      _preview([_msg('1', 'kaitlyn', '', attachment: _file('image/jpeg'))]),
      isA<RoomPreview>()
          .having((p) => p.text, 'text', 'Photo')
          .having((p) => p.icon, 'icon', PreviewIcon.photo),
    );
    expect(
      _preview([
        _msg('1', 'kaitlyn', 'sunny spot', attachment: _file('image/jpeg')),
      ]).text,
      'sunny spot',
    );
    expect(
      _preview([_msg('1', 'kaitlyn', '', attachment: _file('video/mp4'))]),
      isA<RoomPreview>()
          .having((p) => p.text, 'text', 'Video')
          .having((p) => p.icon, 'icon', PreviewIcon.video),
    );
  });

  test('a voice message shows its length when known', () {
    expect(
      _preview([
        _msg(
          '1',
          'kaitlyn',
          '',
          attachment: _file('audio/m4a', durationMs: 42400),
        ),
      ]).text,
      'Voice message · 0:42',
    );
    expect(
      _preview([_msg('1', 'kaitlyn', '', attachment: _file('audio/m4a'))]).text,
      'Voice message',
    );
  });

  test('line breaks and runs of spaces collapse to single spaces', () {
    final p = _preview([_msg('1', 'kaitlyn', '  oat milk\n\neggs   bread ')]);
    expect(p.text, 'oat milk eggs bread');
  });

  test('the unread count passes through', () {
    expect(_preview([_msg('1', 'kaitlyn', 'hi')], unread: 3).unread, 3);
  });
}
