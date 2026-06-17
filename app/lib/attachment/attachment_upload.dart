import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';

/// Request a presigned PUT for [ciphertext] in [roomId], then upload the raw
/// bytes to R2. Returns the server-minted `blob_key`. Throws on timeout or a
/// non-2xx PUT. The caller has already encrypted the bytes (raw ciphertext is
/// uploaded — never base64 — to bound memory; spec §4).
Future<String> uploadCiphertext({
  required LiveConnection conn,
  required String roomId,
  required Uint8List ciphertext,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final requestId = const Uuid().v4();
  final granted = conn.incoming
      .where((f) => f is UploadGrantedFrame && f.requestId == requestId)
      .cast<UploadGrantedFrame>()
      .first
      .timeout(timeout);

  conn.send(
    RequestUploadFrame(
      requestId: requestId,
      roomId: roomId,
      byteSize: ciphertext.length,
    ).toJson(),
  );

  final grant = await granted;
  final client = httpClient ?? http.Client();
  try {
    final res = await client.put(
      Uri.parse(grant.url),
      headers: const {'content-type': 'application/octet-stream'},
      body: ciphertext,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw http.ClientException('R2 PUT failed: HTTP ${res.statusCode}');
    }
    return grant.blobKey;
  } finally {
    if (httpClient == null) client.close();
  }
}
