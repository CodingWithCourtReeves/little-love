import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

/// A built thumbnail: a small JPEG plus the ORIGINAL media's pixel dimensions
/// (used for the descriptor's width/height so the bubble can size its tile).
class BuiltThumbnail {
  BuiltThumbnail({
    required this.jpeg,
    required this.width,
    required this.height,
  });
  final Uint8List jpeg;
  final int width;
  final int height;
}

// Long edge of the inline preview. The tile renders at ~240pt (≈720px on a 3×
// screen), so a larger thumb than the old 180px reads much sharper.
const _maxEdge = 360;

// Hard cap on the encoded thumbnail (raw JPEG bytes). The thumb is base64'd
// into the descriptor AND the whole envelope is base64'd again when encrypted,
// so a jpeg of N bytes costs ~N·1.88 in the wire body. The server caps each
// body at 96 KiB (MAX_BODY_BYTES), so keeping the jpeg ≤44 KiB leaves the body
// near ~85 KiB with headroom for the key/metadata fields.
const _maxThumbBytes = 44 * 1024;

// Tried high → low; the first encoding that fits [_maxThumbBytes] wins. The
// lowest step always fits at this resolution, so a thumb is always produced.
const _qualitySteps = [82, 72, 62, 52, 42, 32];

/// Encode [image] as the highest-quality JPEG that fits [maxBytes].
Uint8List _encodeUnderBudget(img.Image image, [int maxBytes = _maxThumbBytes]) {
  late Uint8List out;
  for (final q in _qualitySteps) {
    out = Uint8List.fromList(img.encodeJpg(image, quality: q));
    if (out.length <= maxBytes) break;
  }
  return out;
}

/// Downscale image [bytes] to a JPEG no wider/taller than [maxEdge] and no
/// larger than [maxThumbBytes] (quality fitted to the budget). Returns the
/// original dimensions alongside the thumbnail. Defaults suit inline message
/// thumbnails; link-preview images pass a smaller budget to stay well under
/// the per-recipient body cap.
Future<BuiltThumbnail> buildImageThumbnail(
  Uint8List bytes, {
  int maxEdge = _maxEdge,
  int maxThumbBytes = _maxThumbBytes,
}) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('undecodable image');
  final w = decoded.width, h = decoded.height;
  final thumb = w >= h
      ? img.copyResize(decoded, width: maxEdge)
      : img.copyResize(decoded, height: maxEdge);
  return BuiltThumbnail(
    jpeg: _encodeUnderBudget(thumb, maxThumbBytes),
    width: w,
    height: h,
  );
}

/// Extract a poster frame from a video file at [path] and downscale it.
/// iOS-only path (AVAssetImageGenerator under the hood). Dimensions are the
/// poster's, which match the video's display size.
Future<BuiltThumbnail> buildVideoThumbnail(String path) async {
  final jpeg = await vt.VideoThumbnail.thumbnailData(
    video: path,
    imageFormat: vt.ImageFormat.JPEG,
    maxWidth: _maxEdge,
    // Request near-lossless from the extractor, then re-encode to fit budget.
    quality: 90,
  );
  if (jpeg == null) {
    throw const FormatException('could not extract video poster');
  }
  final decoded = img.decodeImage(jpeg);
  if (decoded == null) {
    // Can't re-encode; ship the extractor's JPEG as-is.
    return BuiltThumbnail(jpeg: jpeg, width: 0, height: 0);
  }
  return BuiltThumbnail(
    jpeg: _encodeUnderBudget(decoded),
    width: decoded.width,
    height: decoded.height,
  );
}
