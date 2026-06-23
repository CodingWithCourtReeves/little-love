import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_descriptor.dart';

@immutable
class PartnerProfile {
  const PartnerProfile({
    required this.username,
    required this.displayName,
    required this.avatar,
    required this.updatedAt,
  });
  final String username;
  final String? displayName;
  final AttachmentDescriptor? avatar;
  final DateTime updatedAt;
}

/// Holds the decrypted profile of the partner, keyed by username. Last-writer-
/// wins by [PartnerProfile.updatedAt] so an out-of-order or replayed frame never
/// clobbers a newer one.
class ProfileStore extends ChangeNotifier {
  final Map<String, PartnerProfile> _byUsername = {};

  /// Decrypted partner avatar images, keyed by username. Populated after the
  /// avatar blob is fetched + decrypted (the descriptor only names the blob).
  final Map<String, File> _avatarFiles = {};

  PartnerProfile? forUsername(String username) => _byUsername[username];

  /// The on-disk decrypted avatar for [username], or null until it's fetched.
  File? avatarFileFor(String username) => _avatarFiles[username];

  void apply(PartnerProfile p) {
    final existing = _byUsername[p.username];
    if (existing != null && !p.updatedAt.isAfter(existing.updatedAt)) return;
    _byUsername[p.username] = p;
    notifyListeners();
  }

  /// Record the decrypted avatar file for [username] and notify listeners so the
  /// room list / chat header re-render with the image.
  void setAvatarFile(String username, File file) {
    _avatarFiles[username] = file;
    notifyListeners();
  }
}

final profileStoreProvider = ChangeNotifierProvider<ProfileStore>(
  (_) => ProfileStore(),
);
