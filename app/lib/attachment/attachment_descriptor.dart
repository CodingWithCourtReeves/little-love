import 'dart:convert';
import 'dart:typed_data';

import 'file_crypto.dart';

/// The `kind:"file"` payload carried inside the per-recipient encrypted message
/// body (spec §3). Holds the per-file content key + metadata + an inline
/// encrypted thumbnail. Full file bytes live in R2 under [blobKey].
class AttachmentDescriptor {
  const AttachmentDescriptor({
    required this.blobKey,
    required this.contentKeyB64,
    required this.nonceB64,
    required this.mime,
    required this.filename,
    required this.size,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.thumbB64,
    this.waveform,
  });

  final String blobKey;
  final String contentKeyB64;
  final String nonceB64;
  final String mime;
  final String filename;
  final int size;
  final int width;
  final int height;
  final int? durationMs;
  final String thumbB64;

  /// For `kind:"audio"`: ~64 amplitude peaks (0..31) drawn as the static bar
  /// waveform. Null for non-audio attachments. Rides inside the already-
  /// encrypted descriptor, so no separate blob is needed.
  final List<int>? waveform;

  bool get isVideo => mime.startsWith('video/');

  bool get isAudio => mime.startsWith('audio/');

  Map<String, Object?> toJson() => {
    'blob_key': blobKey,
    'content_key': contentKeyB64,
    'nonce': nonceB64,
    'mime': mime,
    'filename': filename,
    'size': size,
    'width': width,
    'height': height,
    if (durationMs != null) 'duration_ms': durationMs,
    'thumb': thumbB64,
    if (waveform != null) 'waveform': waveform,
  };

  factory AttachmentDescriptor.fromJson(Map<String, Object?> j) {
    final mime = j['mime']! as String;
    return AttachmentDescriptor(
      blobKey: j['blob_key']! as String,
      contentKeyB64: j['content_key']! as String,
      nonceB64: j['nonce']! as String,
      mime: mime,
      filename: (j['filename'] as String?) ?? '',
      size: (j['size'] as num).toInt(),
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      durationMs: (j['duration_ms'] as num?)?.toInt(),
      // Audio carries no thumbnail; for image/video keep the fail-fast
      // (a missing thumb is a corrupt descriptor) rather than deferring the
      // crash to render time inside decodeThumb.
      thumbB64: mime.startsWith('audio/')
          ? ((j['thumb'] as String?) ?? '')
          : j['thumb']! as String,
      waveform: (j['waveform'] as List?)
          ?.map((e) => (e as num).toInt())
          .toList(),
    );
  }
}

/// Encrypt a thumbnail JPEG into a self-contained wire string:
/// base64( key[32] || nonce[24] || ciphertext ).
Future<String> encodeThumb(Uint8List jpeg) async {
  final enc = await encryptFileBytes(jpeg);
  final out = Uint8List(32 + 24 + enc.ciphertext.length)
    ..setRange(0, 32, enc.key)
    ..setRange(32, 56, enc.nonce)
    ..setRange(56, 56 + enc.ciphertext.length, enc.ciphertext);
  return base64.encode(out);
}

Future<Uint8List> decodeThumb(String wire) async {
  final raw = base64.decode(wire);
  if (raw.length < 56) throw const FormatException('thumb too short');
  final key = Uint8List.sublistView(raw, 0, 32);
  final nonce = Uint8List.sublistView(raw, 32, 56);
  final ct = Uint8List.sublistView(raw, 56);
  return decryptFileBytes(key: key, nonce: nonce, ciphertext: ct);
}
