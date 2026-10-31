import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachment/attachment_download.dart';
import '../channel/channel_picture_provider.dart';
import '../channel/pending_channel_actions.dart';
import '../conversation/draft_preview_state.dart';
import '../conversation/message_db.dart';
import '../conversation/room_hydration_state.dart';
import '../conversation/staged_media_store.dart';
import '../diagnostics/crash_reporting.dart';
import '../inbox/active_room_provider.dart';
import '../inbox/inbox_state.dart';
import '../inbox/read_state_provider.dart';
import '../outbox/outbox_store.dart';
import '../profile/profile_publish_cache.dart';
import '../profile/profile_store.dart';
import 'providers.dart';

/// Deletes the on-disk decrypted media cache. A missing folder is fine. A
/// provider so widget tests (fake-async zone, where real file I/O never
/// completes) can swap in a no-op.
final attachmentCacheWipeProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => attachmentsCacheDir().then((d) async {
        if (await d.exists()) await d.delete(recursive: true);
      }),
);

/// Sign the current account out of this device: wipe the local identity and all
/// per-account local data, then reset the session so [AuthGate] returns to the
/// signup/sign-in choice screen.
///
/// This is destructive and irreversible without the recovery phrase. It removes
/// the master seed from the keychain, the local account record, the read-state
/// file, and the outbox queue, then invalidates [accountProvider] — which
/// cascades to tear down the live socket and identity (both watch it).
Future<void> signOut(WidgetRef ref) async {
  final username = ref.read(accountProvider).valueOrNull?.username;

  // Outbox wipe so a new account on this device never re-sends the old user's
  // queued messages. The outbox is a single device-global DB (see
  // `outbox_store.dart` — `<app-support>/outbox.db`, not account-scoped), so a
  // fire-and-forget clear can lose the race with the next account's send loop
  // and leak the previous user's ciphertext. Await it. Stay best-effort,
  // though — a failed clear must not abort sign-out — and don't touch `ref` in
  // the callback (the await itself is safe before the disposal below).
  final outboxFuture = ref.read(outboxStoreProvider.future);
  await outboxFuture.then((s) => s.clear()).catchError((_) {});

  // Same reasoning for the local decrypted-message store: it's a single
  // device-global SQLCipher DB (`<app-support>/messages.db`, not account-scoped),
  // so a new account on this device could otherwise read the previous user's
  // plaintext history. Await it, best-effort.
  final messageDbFuture = ref.read(messageDbProvider.future);
  await messageDbFuture.then((db) => db.clear()).catchError((_) {});

  // Decrypted received media and channel pictures cached on disk. The cache is
  // device-global (not account-scoped), so a new account would otherwise find
  // the previous couple's photos. Await it; best-effort.
  await ref.read(attachmentCacheWipeProvider)().catchError((_) {
    // Best-effort: a failed delete must not abort sign-out, and there is
    // nothing useful to do about it here.
  });

  // 1. Persisted identity + per-account data.
  if (username != null) {
    await ref.read(keystoreProvider).delete('llove.master.$username');
  }
  await ref.read(accountLocalStoreProvider).delete();
  await ref.read(readStateStoreProvider).clear();
  // Drop the persisted avatar descriptor/blob key, or a new account on this
  // device would re-publish the previous user's avatar (ensureAvatarUploaded
  // short-circuits on the cache hit before reading the new avatarPath).
  await ref
      .read(profilePublishCacheProvider)
      .setAvatar(null, null)
      .catchError((_) {});
  // Clear the crash-reporting opt-in so a new account on this device doesn't
  // inherit the previous user's consent (and stop any live transmission now).
  await CrashReporting.onSignOut().catchError((_) {});

  // 2. In-memory session state that doesn't watch accountProvider.
  ref.invalidate(inboxStateProvider);
  ref.invalidate(inboxSyncedProvider);
  ref.invalidate(readStateProvider);
  ref.invalidate(activeRoomProvider);
  ref.invalidate(requestedRoomProvider);
  // The partner's decrypted profile + cached avatar files belong to this couple.
  ref.invalidate(profileStoreProvider);
  // Media staged on a composer but never sent (in memory only; the text half
  // of the draft went with messageDb.clear() above).
  ref.invalidate(stagedMediaProvider);
  // Per-room home-list state: the draft previews (their text was wiped with
  // messageDb.clear() above) and whether each room's history has loaded.
  ref.invalidate(draftPreviewProvider);
  ref.invalidate(roomHydratedProvider);
  // Channel pictures: the queued channel actions, the resolved picture per
  // channel, and the decrypted photo files (deleted from disk above).
  ref.invalidate(pendingChannelActionsProvider);
  ref.invalidate(currentChannelPictureProvider);
  ref.invalidate(channelPhotoFileProvider);
  // Reset the toggle's state so the next account sees it off (matches the
  // cleared pref above).
  ref.invalidate(crashReportingProvider);
  // NOTE: deliberately do NOT clear pendingPairCodeProvider here. A
  // /pair/<code> link captured at cold launch is pulled from the native
  // buffer exactly once (takePendingLaunchLink); the legitimate invitee flow
  // is "tap link → sign out of the old account → sign up → auto-pair", which
  // needs the captured code to survive sign-out. A truly stale/expired code
  // fails gracefully on consume, so there's nothing to defend against here.

  // 3. Drop back to the choice screen; this also disposes the live socket and
  // identity, which both watch accountProvider.
  ref.invalidate(accountProvider);
}
