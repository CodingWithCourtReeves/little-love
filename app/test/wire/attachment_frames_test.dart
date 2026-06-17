import 'package:flutter_test/flutter_test.dart';
import 'package:littlelove/wire/frames.dart';

void main() {
  test('RequestUpload serializes', () {
    final j = const RequestUploadFrame(
      requestId: 'req-1',
      roomId: '01J',
      byteSize: 1048576,
    ).toJson();
    expect(j['kind'], 'RequestUpload');
    expect(j['byte_size'], 1048576);
  });

  test('RequestDownload serializes', () {
    expect(
      const RequestDownloadFrame(blobKey: '01JBLOB').toJson()['blob_key'],
      '01JBLOB',
    );
  });

  test('UploadGranted parses', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'UploadGranted',
      'request_id': 'req-1',
      'blob_key': '01JBLOB',
      'url': 'https://r2/put',
      'expires_at': '2026-06-16T18:00:00Z',
    });
    expect(f, isA<UploadGrantedFrame>());
    expect((f as UploadGrantedFrame).blobKey, '01JBLOB');
  });

  test('DownloadGranted parses', () {
    final f = RoomServerFrame.fromJson({
      'kind': 'DownloadGranted',
      'blob_key': '01JBLOB',
      'url': 'https://r2/get',
      'expires_at': '2026-06-16T18:00:00Z',
    });
    expect(f, isA<DownloadGrantedFrame>());
  });
}
