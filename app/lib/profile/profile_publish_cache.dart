import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../attachment/attachment_descriptor.dart';

/// Persists the avatar descriptor + blob key of the profile last published, so a
/// reconnect (or a first connection after a pre-pairing edit) can re-assert the
/// full profile to the partner WITHOUT re-encrypting and re-uploading the photo.
/// The display name itself already lives on `LocalAccount`; only the avatar
/// descriptor needs this side store.
class ProfilePublishCache {
  static const _kDescriptor = 'profile.avatar.descriptor';
  static const _kBlobKey = 'profile.avatar.blob_key';

  /// Store (or clear, when [descriptor] is null) the last-published avatar.
  Future<void> setAvatar(
    AttachmentDescriptor? descriptor,
    String? blobKey,
  ) async {
    final p = await SharedPreferences.getInstance();
    if (descriptor == null || blobKey == null) {
      await p.remove(_kDescriptor);
      await p.remove(_kBlobKey);
      return;
    }
    await p.setString(_kDescriptor, jsonEncode(descriptor.toJson()));
    await p.setString(_kBlobKey, blobKey);
  }

  Future<AttachmentDescriptor?> avatar() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kDescriptor);
    if (raw == null) return null;
    try {
      return AttachmentDescriptor.fromJson(
        jsonDecode(raw) as Map<String, Object?>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> avatarKey() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kBlobKey);
  }
}

final profilePublishCacheProvider = Provider<ProfilePublishCache>(
  (_) => ProfilePublishCache(),
);
