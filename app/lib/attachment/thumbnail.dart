import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

/// A built thumbnail: a small JPEG plus the ORIGINAL media's pixel dimensions
/// (used for the descriptor's width/height so the bubble can size its tile).
class BuiltThumbnail {
  BuiltThumbnail({required this.jpeg, required this.width, required this.height});
  final Uint8List jpeg;
  final int width;
  final int height;
}

const _maxEdge = 180;
const _quality = 50;

/// Downscale image [bytes] to a <=180px-long-edge JPEG. Returns the original
/// dimensions alongside the thumbnail.
Future<BuiltThumbnail> buildImageThumbnail(Uint8List bytes) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('undecodable image');
  final w = decoded.width, h = decoded.height;
  final thumb = w >= h
      ? img.copyResize(decoded, width: _maxEdge)
      : img.copyResize(decoded, height: _maxEdge);
  return BuiltThumbnail(
    jpeg: Uint8List.fromList(img.encodeJpg(thumb, quality: _quality)),
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
    quality: _quality,
  );
  if (jpeg == null) throw const FormatException('could not extract video poster');
  final decoded = img.decodeImage(jpeg);
  return BuiltThumbnail(
    jpeg: jpeg,
    width: decoded?.width ?? 0,
    height: decoded?.height ?? 0,
  );
}
