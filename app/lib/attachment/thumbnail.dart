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

// Tried high → low; the first encoding that fits [_maxThumbBytes] wins.
const _qualitySteps = [82, 72, 62, 52, 42, 32];

// Smallest long edge we'll shrink to while chasing the byte budget. A thumb
// this small (a busy 200px JPEG at q32 is only a few KiB) reliably fits any
// sane budget, so the loop always terminates with a result under cap.
const _minBudgetEdge = 200;

/// Encode [image] as the highest-quality JPEG that fits [maxBytes]. Tries the
/// quality ladder at full size first; if even the lowest quality overflows
/// (a complex image can), downscales ~15% and retries, repeating down to
/// [_minBudgetEdge]. Guarantees the result is ≤ [maxBytes] (the only way it
/// returns over budget is if a [_minBudgetEdge]-wide image at q32 still doesn't
/// fit, which doesn't happen for the budgets we use) so an oversized thumb can
/// never push the encrypted body past the server's per-recipient cap.
Uint8List _encodeUnderBudget(img.Image image, [int maxBytes = _maxThumbBytes]) {
  var current = image;
  late Uint8List out;
  while (true) {
    for (final q in _qualitySteps) {
      out = Uint8List.fromList(img.encodeJpg(current, quality: q));
      if (out.length <= maxBytes) return out;
    }
    // Lowest quality still overflowed: shrink and try the ladder again.
    final longEdge = current.width >= current.height
        ? current.width
        : current.height;
    if (longEdge <= _minBudgetEdge) return out; // best effort; floor reached
    final nextEdge = (longEdge * 85 ~/ 100).clamp(_minBudgetEdge, longEdge - 1);
    current = current.width >= current.height
        ? img.copyResize(current, width: nextEdge)
        : img.copyResize(current, height: nextEdge);
  }
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
