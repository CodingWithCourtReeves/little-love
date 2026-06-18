import 'dart:typed_data';

/// A media item the user has picked but not yet sent. It sits in the composer's
/// staging tray so a photo/video can ride out with a typed caption (the caption
/// attaches to the last item of a multi-pick). Encryption + upload only happen
/// on send, so this just holds the raw bytes + metadata needed to build the
/// `kind:"file"` envelope and a lightweight tray preview.
class StagedAttachment {
  const StagedAttachment({
    required this.bytes,
    required this.filename,
    required this.mime,
    this.videoPath,
  });

  final Uint8List bytes;
  final String filename;
  final String mime;

  /// On-disk path of the picked video, needed to build a frame thumbnail at
  /// send time. Null for images.
  final String? videoPath;

  bool get isVideo => mime.startsWith('video/');
}
