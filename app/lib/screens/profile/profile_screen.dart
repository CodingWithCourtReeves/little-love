import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../attachment/attachment_descriptor.dart';
import '../../conversation/room_key_cache.dart';
import '../../diagnostics/crash_reporting.dart';
import '../../identity/account_local.dart';
import '../../identity/current_identity.dart';
import '../../identity/providers.dart';
import '../../identity/sign_out.dart';
import '../../inbox/inbox_state.dart';
import '../../profile/avatar.dart';
import '../../profile/profile_publish_cache.dart';
import '../../profile/profile_service.dart';
import '../../theme/app_palette.dart';
import '../../wallpaper/wallpaper_picker.dart';
import '../../wire/live_connection.dart';

/// Personal settings, reached by tapping your own avatar on the home screen:
/// set an E2EE avatar + display name (synced to your partner), pick a chat
/// wallpaper, see your immutable handle, and sign out.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameCtl = TextEditingController();
  // The last display name we pushed into the field. Lets us reseed when the
  // account updates externally without clobbering an in-progress edit.
  String _seededName = '';
  bool _busy = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountProvider);
    return Scaffold(
      backgroundColor: context.palette.bgCanvas,
      appBar: AppBar(
        backgroundColor: context.palette.bgSurface,
        elevation: 0,
        title: const Text('Profile'),
      ),
      body: accountAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Could not load profile.')),
        data: (account) {
          if (account == null) {
            return const Center(child: Text('No account on this device.'));
          }
          final loaded = account.displayName ?? '';
          // Reseed only when the field hasn't been touched since our last seed,
          // so an external account update is reflected but an in-progress edit
          // is never clobbered.
          if (_nameCtl.text == _seededName && _nameCtl.text != loaded) {
            _nameCtl.text = loaded;
          }
          _seededName = loaded;
          return _content(account);
        },
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: Theme.of(context).textTheme.labelSmall?.copyWith(
      color: context.palette.textMuted,
      letterSpacing: 1.2,
    ),
  );

  Widget _content(LocalAccount account) {
    final hasName = account.displayName?.isNotEmpty ?? false;
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: GestureDetector(
                  key: const Key('profile-avatar'),
                  onTap: _busy ? null : () => _pickAvatar(account),
                  child: Avatar(
                    seedText: hasName ? account.displayName! : account.username,
                    imageFile: account.avatarPath != null
                        ? File(account.avatarPath!)
                        : null,
                    radius: 48,
                  ),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: _busy ? null : () => _pickAvatar(account),
                  child: const Text('Change photo'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('profile-display-name'),
                controller: _nameCtl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  hintText: 'Add a display name',
                ),
                onSubmitted: (_) => _saveDisplayName(account),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('profile-save-name'),
                  onPressed: _busy ? null : () => _saveDisplayName(account),
                  child: const Text('Save'),
                ),
              ),
              const Divider(height: 32),
              _sectionLabel('WALLPAPER'),
              const SizedBox(height: 12),
              const WallpaperPicker(),
              const Divider(height: 32),
              _sectionLabel('YOUR HANDLE'),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('@${account.username}'),
                subtitle: const Text(
                  "This is how your partner found you. It can't be changed.",
                ),
              ),
              // Only offered when a DSN was compiled in; off by default.
              if (crashReportingAvailable) ...[
                const Divider(height: 32),
                _sectionLabel('DIAGNOSTICS'),
                SwitchListTile(
                  key: const Key('profile-crash-reporting'),
                  contentPadding: EdgeInsets.zero,
                  value: ref.watch(crashReportingProvider),
                  onChanged: _busy
                      ? null
                      : (v) => ref
                            .read(crashReportingProvider.notifier)
                            .setEnabled(v),
                  title: const Text('Share crash reports'),
                  subtitle: const Text(
                    'Send crash and error reports to help us fix bugs. They '
                    'never include your messages, names, or contacts, only '
                    'technical details about what went wrong, and they go only '
                    'to our own servers. You can turn this off anytime.',
                  ),
                ),
              ],
              const Divider(height: 32),
              TextButton(
                key: const Key('profile-sign-out'),
                onPressed: _busy ? null : _confirmSignOut,
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Sign out'),
                ),
              ),
            ],
          ),
        ),
        if (_busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x33000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  Future<void> _saveDisplayName(LocalAccount account) async {
    final text = _nameCtl.text.trim();
    // v1 can't clear an existing name to null (LocalAccount.copyWith coalesces);
    // an empty field is a no-op rather than a clear.
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final LocalAccount updated;
    try {
      updated = account.copyWith(displayName: text);
      await ref.read(accountLocalStoreProvider).save(updated);
      ref.invalidate(accountProvider);
    } catch (e, st) {
      reportFault(e, st, context: 'profile_name_save');
      _toast("Couldn't save");
      if (mounted) setState(() => _busy = false);
      return;
    }
    // Sync to the partner is best-effort; the name is already saved locally.
    var synced = true;
    try {
      await _publish(updated);
    } catch (_) {
      synced = false;
    }
    _toast(synced ? 'Saved' : 'Saved — will sync when connected');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickAvatar(LocalAccount account) async {
    final XFile? picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 100,
    );
    if (picked == null) return;
    setState(() => _busy = true);
    final LocalAccount updated;
    // Phase 1: the local update. This is what "update photo" means to the user;
    // if it fails, that's the real failure.
    try {
      final raw = await picked.readAsBytes();
      final squared = _squareJpeg(raw, 512);
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(squared, flush: true);
      // Drop the previous avatar file so they don't accumulate.
      final old = account.avatarPath;
      if (old != null && old != path) {
        try {
          await File(old).delete();
        } catch (_) {}
      }
      updated = account.copyWith(avatarPath: path);
      await ref.read(accountLocalStoreProvider).save(updated);
      ref.invalidate(accountProvider);
      // New photo → drop any previously-uploaded descriptor so the sync path
      // (here and the connect-time retry) re-uploads this one.
      await ref.read(profilePublishCacheProvider).setAvatar(null, null);
    } catch (_) {
      _toast("Couldn't update photo");
      if (mounted) setState(() => _busy = false);
      return;
    }
    // Phase 2: sync to the partner (encrypt → upload → publish). Best-effort —
    // a network/upload failure does NOT mean the photo didn't update; it just
    // hasn't synced yet. The connect-time retry re-uploads it on the next
    // stable connection.
    var synced = true;
    try {
      await _publishAvatar(updated);
    } catch (_) {
      synced = false;
    }
    _toast(
      synced ? 'Photo updated' : 'Photo updated — will sync when connected',
    );
    if (mounted) setState(() => _busy = false);
  }

  /// Center-crop to a square and resize to [size]², encoded as JPEG.
  Uint8List _squareJpeg(Uint8List bytes, int size) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw const FormatException('undecodable image');
    final side = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final x = (decoded.width - side) ~/ 2;
    final y = (decoded.height - side) ~/ 2;
    final cropped = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: side,
      height: side,
    );
    final resized = img.copyResize(cropped, width: size, height: size);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
  }

  /// Upload the avatar (via the shared, retry-able helper) and publish the full
  /// profile. No-ops before pairing/connection (the photo stays local; the
  /// connect-time retry re-asserts it once paired and connected).
  Future<void> _publishAvatar(LocalAccount account) async {
    final conn = ref.read(liveConnectionProvider).valueOrNull;
    final rooms = ref.read(inboxStateProvider).rooms;
    final room = coupleRoomFor(rooms, account.username);
    if (conn == null || room == null) return;
    final descriptor = await ensureAvatarUploaded(
      conn: conn,
      room: room,
      avatarPath: account.avatarPath,
      cache: ref.read(profilePublishCacheProvider),
    );
    await _publishWith(account, descriptor, descriptor?.blobKey);
  }

  /// Publish a display-name change, carrying the existing cached avatar so it
  /// isn't cleared.
  Future<void> _publish(LocalAccount account) async {
    final cache = ref.read(profilePublishCacheProvider);
    final avatar = await cache.avatar();
    final avatarKey = await cache.avatarKey();
    await _publishWith(account, avatar, avatarKey);
  }

  Future<void> _publishWith(
    LocalAccount account,
    AttachmentDescriptor? avatar,
    String? avatarKey,
  ) async {
    final conn = ref.read(liveConnectionProvider).valueOrNull;
    final me = await ref.read(currentIdentityProvider.future);
    await assembleAndPublishProfile(
      conn: conn,
      rooms: ref.read(inboxStateProvider).rooms,
      selfUsername: account.username,
      displayName: account.displayName,
      me: me,
      keyCache: ref.read(roomKeyCacheProvider),
      avatar: avatar,
      avatarKey: avatarKey,
    );
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes this account and its messages from this device. You '
          'can sign back in with your recovery phrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-signout'),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await signOut(ref);
    // Leave the (now identity-less) profile screen so AuthGate's signup screen,
    // rebuilt underneath, is revealed.
    if (mounted) Navigator.of(context).maybePop();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
