import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../wire/live_connection.dart';
import 'attachment_descriptor.dart';
import 'attachment_upload.dart';
import 'file_crypto.dart';
import 'thumbnail.dart';

/// Center-crop to a square and resize to [size]², encoded as JPEG.
Uint8List squareJpeg(Uint8List bytes, {int size = 512}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('undecodable image');
  final side = decoded.width < decoded.height ? decoded.width : decoded.height;
  final x = (decoded.width - side) ~/ 2;
  final y = (decoded.height - side) ~/ 2;
  final cropped = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  final resized = img.copyResize(cropped, width: size, height: size);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
}

/// Encrypt [jpeg], upload it to [roomId]'s blob store and return its
/// descriptor (with a small inline thumbnail). Shared by the profile avatar and
/// channel pictures. Throws if the upload fails.
Future<AttachmentDescriptor> uploadSquareImage({
  required LiveConnection conn,
  required String roomId,
  required Uint8List jpeg,
  required String filename,
}) async {
  final enc = await encryptFileBytes(jpeg);
  final blobKey = await uploadCiphertext(
    conn: conn,
    roomId: roomId,
    ciphertext: enc.ciphertext,
  );
  final thumb = await buildImageThumbnail(
    jpeg,
    maxEdge: 128,
    maxThumbBytes: 12 * 1024,
  );
  return AttachmentDescriptor(
    blobKey: blobKey,
    contentKeyB64: base64.encode(enc.key),
    nonceB64: base64.encode(enc.nonce),
    mime: 'image/jpeg',
    filename: filename,
    size: jpeg.length,
    width: thumb.width,
    height: thumb.height,
    durationMs: null,
    thumbB64: base64.encode(thumb.jpeg),
  );
}
