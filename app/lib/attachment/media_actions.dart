import 'dart:io';

import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import 'attachment_descriptor.dart';

/// Shared save/share actions for a decrypted attachment file. Used by both the
/// full-screen [AttachmentViewer] and the bubble long-press menu so the two
/// surfaces stay in lockstep.

/// Save a decrypted image/video to the camera roll (add-only Photos access).
/// Throws on permission denial or an unsupported type; callers surface the
/// failure as a toast.
Future<void> saveToGallery(File file, AttachmentDescriptor descriptor) async {
  if (!await Gal.hasAccess(toAlbum: true)) {
    await Gal.requestAccess(toAlbum: true);
  }
  if (descriptor.isVideo) {
    await Gal.putVideo(file.path);
  } else {
    await Gal.putImage(file.path);
  }
}

/// Hand a decrypted attachment file to the iOS share sheet.
Future<void> shareFile(File file, AttachmentDescriptor descriptor) async {
  await Share.shareXFiles([
    XFile(file.path, mimeType: descriptor.mime, name: descriptor.filename),
  ]);
}
