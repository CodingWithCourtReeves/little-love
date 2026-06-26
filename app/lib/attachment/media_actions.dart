import 'dart:io';

import 'package:gal/gal.dart';

import 'attachment_descriptor.dart';

/// Save a decrypted attachment to the camera roll. Shared by the full-screen
/// [AttachmentViewer] and the bubble long-press menu so both surfaces stay in
/// lockstep.

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
