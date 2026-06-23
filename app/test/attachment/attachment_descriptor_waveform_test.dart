import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/attachment/attachment_descriptor.dart';

AttachmentDescriptor _audio({List<int>? wave}) => AttachmentDescriptor(
  blobKey: 'k',
  contentKeyB64: 'c',
  nonceB64: 'n',
  mime: 'audio/mp4',
  filename: 'memo.m4a',
  size: 1234,
  width: 0,
  height: 0,
  durationMs: 4200,
  thumbB64: '',
  waveform: wave,
);

void main() {
  test('waveform round-trips through toJson/fromJson', () {
    final wave = List<int>.generate(64, (i) => i % 32);
    final back = AttachmentDescriptor.fromJson(_audio(wave: wave).toJson());
    expect(back.waveform, wave);
    expect(back.durationMs, 4200);
    expect(back.mime, 'audio/mp4');
  });

  test('null waveform is omitted from json and decodes back to null', () {
    final json = _audio(wave: null).toJson();
    expect(json.containsKey('waveform'), isFalse);
    expect(AttachmentDescriptor.fromJson(json).waveform, isNull);
  });

  test('fromJson tolerates a missing thumb key (audio has no thumbnail)', () {
    final json = _audio(wave: [1, 2, 3]).toJson()..remove('thumb');
    final back = AttachmentDescriptor.fromJson(json);
    expect(back.thumbB64, '');
    expect(back.waveform, [1, 2, 3]);
  });

  test('isAudio reflects the mime type', () {
    expect(_audio().isAudio, isTrue);
  });
}
