import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../wire/frames.dart';
import '../wire/live_connection.dart';
import 'attachment_descriptor.dart';
import 'file_crypto.dart';

/// Fetch + decrypt the full file for [descriptor], returning a local plaintext
/// file. Cached by `blob_key` under app-support so re-opening is instant. The
/// content key/nonce come from the (already-decrypted) descriptor; the server
/// never sees them.
Future<File> fetchAndDecrypt({
  required LiveConnection conn,
  required AttachmentDescriptor descriptor,
  http.Client? httpClient,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final dir = await getApplicationSupportDirectory();
  final cacheDir = Directory(p.join(dir.path, 'attachments'));
  await cacheDir.create(recursive: true);
  final cached = File(p.join(cacheDir.path, descriptor.blobKey));
  if (await cached.exists()) return cached;

  final granted = conn.incoming
      .where((f) => f is DownloadGrantedFrame && f.blobKey == descriptor.blobKey)
      .cast<DownloadGrantedFrame>()
      .first
      .timeout(timeout);
  conn.send(RequestDownloadFrame(blobKey: descriptor.blobKey).toJson());
  final grant = await granted;

  final client = httpClient ?? http.Client();
  try {
    final res = await client.get(Uri.parse(grant.url));
    if (res.statusCode != 200) {
      throw http.ClientException('R2 GET failed: HTTP ${res.statusCode}');
    }
    final plain = await decryptFileBytes(
      key: base64ToBytes(descriptor.contentKeyB64),
      nonce: base64ToBytes(descriptor.nonceB64),
      ciphertext: res.bodyBytes,
    );
    // Write atomically: temp then rename, so a crash mid-write can't leave a
    // truncated file masquerading as a complete cache hit.
    final tmp = File('${cached.path}.part');
    await tmp.writeAsBytes(plain, flush: true);
    await tmp.rename(cached.path);
    return cached;
  } finally {
    if (httpClient == null) client.close();
  }
}
